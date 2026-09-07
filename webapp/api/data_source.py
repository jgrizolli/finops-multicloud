"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Camada de dados. Aqui mora a unica parte da aplicacao que sabe DE ONDE o dado vem.

Tres fontes, um contrato:
  FonteStorage   le os parquet FOCUS do container ingestion do FinOps hub (nivel 0).
  FonteKusto     consulta o banco Hub no Eventhouse do Fabric ou no Data Explorer (nivel 1).
  FonteEstatica  recebe um dataframe pronto. Usada nos testes e na previa.

Todas devolvem o MESMO dataframe normalizado, com as mesmas colunas. A API e a interface
nunca sabem qual fonte esta por baixo. Trocar de storage para Fabric e trocar tres variaveis
de ambiente; nada muda no front.

Autenticacao:
  DefaultAzureCredential. No App Service usa a identidade gerenciada. Na sua maquina, usa o
  login do Azure CLI (az login). Nao ha chave nem segredo em lugar nenhum.

Cache:
  o dado de custo muda uma vez por dia. Manter tudo em memoria por 30 minutos evita reler a
  fonte a cada clique e deixa a interface instantanea.
"""

from __future__ import annotations

import io
import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import pandas as pd

log = logging.getLogger("finops.data")

CONTAINER = "ingestion"
PASTA_CUSTOS = "Costs"
CACHE_TTL_SEGUNDOS = int(os.getenv("CACHE_TTL_SECONDS", "1800"))

# Colunas FOCUS que a interface usa. Ler so o necessario reduz muito memoria e tempo.
COLUNAS_DESEJADAS = [
    "BilledCost", "EffectiveCost", "ListCost", "ContractedCost", "BillingCurrency",
    "ChargePeriodStart", "ChargePeriodEnd", "BillingPeriodStart",
    "ChargeCategory", "ChargeClass", "ChargeDescription", "ChargeFrequency",
    "ServiceName", "ServiceCategory", "ServiceSubcategory",
    "ResourceId", "ResourceName", "ResourceType",
    "RegionId", "RegionName",
    "SubAccountId", "SubAccountName", "BillingAccountName",
    "ProviderName", "PublisherName", "PricingCategory",
    "CommitmentDiscountId", "CommitmentDiscountName", "CommitmentDiscountStatus", "CommitmentDiscountType",
    "ConsumedQuantity", "ConsumedUnit", "PricingQuantity", "PricingUnit",
    "SkuId", "SkuPriceId",
    "x_ResourceGroupName", "x_SourceProvider",
    "x_SkuDescription", "x_SkuMeterName", "SkuMeter", "SkuMeterName",
    "x_SkuMeterCategory", "x_SkuMeterSubcategory",
    "Tags",
]

# Nomes que mudaram entre FOCUS 1.0 e 1.2, ou que sao extensoes. Normalizamos para um nome
# unico para que a interface funcione com qualquer versao sem espalhar "if" pelo codigo.
EQUIVALENCIAS = {
    "x_SkuMeterName": "SkuMeter",
    "SkuMeterName": "SkuMeter",
    "x_ResourceGroupName": "ResourceGroupName",
    "x_SkuDescription": "SkuDescription",
    "x_SkuMeterCategory": "SkuMeterCategory",
    "x_SkuMeterSubcategory": "SkuMeterSubcategory",
}

# Nomes canonicos das nuvens. A cor de cada nuvem no front e fixa e depende deste nome.
NUVENS_CANONICAS = {
    "microsoft": "Microsoft Azure", "azure": "Microsoft Azure", "microsoft azure": "Microsoft Azure",
    "aws": "Amazon Web Services", "amazon": "Amazon Web Services", "amazon web services": "Amazon Web Services",
    "google": "Google Cloud", "gcp": "Google Cloud", "google cloud": "Google Cloud", "google cloud platform": "Google Cloud",
    "oci": "Oracle Cloud", "oracle": "Oracle Cloud", "oracle cloud": "Oracle Cloud", "oracle cloud infrastructure": "Oracle Cloud",
}

TAGS_VAZIAS = {"", "{}", "[]", "null", "None", "nan"}

# Sinais de ambiente nao produtivo, em nomes e em tags. Usado pela otimizacao.
PADRAO_NAO_PROD = re.compile(r"(^|[^a-z])(dev|test|tst|qa|hml|homolog|stag|stg|sandbox|sbx|poc|lab|uat)([^a-z]|$)", re.I)
PADRAO_PROD = re.compile(r"(^|[^a-z])(prod|prd|production)([^a-z]|$)", re.I)


@dataclass
class Carga:
    """Resultado de uma leitura completa da fonte."""

    df: pd.DataFrame = field(default_factory=pd.DataFrame)
    carregado_em: datetime | None = None
    meses: list[str] = field(default_factory=list)
    arquivos: int = 0
    linhas: int = 0
    bytes_lidos: int = 0
    erro: str | None = None
    duracao_segundos: float = 0.0
    tags_por_string: dict = field(default_factory=dict)
    backend: str = ""


# ============================================================================ normalizacao
def parse_tags(valor) -> dict:
    """Converte a coluna Tags (JSON em texto, ou dict vindo do Kusto) em dicionario. Tolerante a lixo."""
    if isinstance(valor, dict):
        return {str(k): ("" if v is None else str(v)) for k, v in valor.items()}
    if valor is None:
        return {}
    s = str(valor).strip()
    if s in TAGS_VAZIAS:
        return {}
    try:
        d = json.loads(s)
        if isinstance(d, dict):
            return {str(k): ("" if v is None else str(v)) for k, v in d.items()}
        if isinstance(d, list):  # alguns exports trazem lista de {key,value}
            return {str(i["key"]): str(i.get("value", "")) for i in d if isinstance(i, dict) and "key" in i}
    except Exception:  # noqa: BLE001
        pass
    return {}


def _tags_para_texto(v) -> str:
    """Serializa a coluna Tags em JSON valido, venha ela como texto (parquet) ou como dict (Kusto)."""
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        try:
            return json.dumps(v, ensure_ascii=False, sort_keys=True)
        except Exception:  # noqa: BLE001
            return ""
    if isinstance(v, float) and v != v:  # NaN
        return ""
    return str(v)


def classificar_ambiente(nome_recurso: str, grupo: str, assinatura: str, tags: dict) -> str:
    """Produção, Não produção ou Desconhecido, a partir de tags e de padrões de nome."""
    for chave in ("Environment", "environment", "env", "Env", "ambiente", "Ambiente", "Stage", "stage"):
        v = tags.get(chave)
        if v:
            if PADRAO_PROD.search(f" {v} "):
                return "Produção"
            if PADRAO_NAO_PROD.search(f" {v} "):
                return "Não produção"
    texto = f" {grupo} {assinatura} {nome_recurso} "
    if PADRAO_NAO_PROD.search(texto):
        return "Não produção"
    if PADRAO_PROD.search(texto):
        return "Produção"
    return "Desconhecido"


def normalizar(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """
    Deixa o dataframe pronto para consulta, independente da versao do FOCUS e da fonte.
    Devolve tambem o mapa TagsStr -> dict, reaproveitado pelas analises de governanca.
    """
    for antigo, novo in EQUIVALENCIAS.items():
        if antigo in df.columns and novo not in df.columns:
            df = df.rename(columns={antigo: novo})
        elif antigo in df.columns and novo in df.columns:
            df[novo] = df[novo].where(df[novo].notna(), df[antigo])
            df = df.drop(columns=[antigo])

    for col in ("BilledCost", "EffectiveCost", "ListCost", "ContractedCost", "ConsumedQuantity", "PricingQuantity"):
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0) if col in df.columns else 0.0

    for col in ("ChargePeriodStart", "ChargePeriodEnd", "BillingPeriodStart"):
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce", utc=True).dt.tz_localize(None)

    if "ChargePeriodStart" in df.columns:
        df["Data"] = df["ChargePeriodStart"].dt.normalize()
        df["Mes"] = df["ChargePeriodStart"].dt.to_period("M").astype(str)
    else:
        df["Data"] = pd.NaT
        df["Mes"] = ""

    # Nuvem: x_SourceProvider vem do hub (nivel 1) e identifica o conector; ProviderName e coluna
    # FOCUS e existe em todo dado (nivel 0). Preferimos o primeiro e caimos no segundo.
    fonte = None
    if "x_SourceProvider" in df.columns:
        fonte = df["x_SourceProvider"]
    if "ProviderName" in df.columns:
        if fonte is None:
            fonte = df["ProviderName"]
        else:
            vazio = fonte.isna() | (fonte.astype(str).str.strip() == "")
            fonte = fonte.where(~vazio, df["ProviderName"])
    if fonte is None:
        fonte = pd.Series("", index=df.index)
    chave = fonte.fillna("").astype(str).str.strip().str.lower()
    df["Nuvem"] = chave.map(NUVENS_CANONICAS).fillna(fonte.fillna("").astype(str))
    df.loc[df["Nuvem"].astype(str).str.strip() == "", "Nuvem"] = "Microsoft Azure"

    padroes = (
        ("ServiceName", "Não informado"), ("ServiceCategory", "Outros"), ("ServiceSubcategory", ""),
        ("RegionName", "Global"), ("ResourceName", ""), ("ResourceId", ""), ("ResourceType", ""),
        ("ResourceGroupName", ""), ("SubAccountName", ""), ("SubAccountId", ""), ("BillingAccountName", ""),
        ("ChargeCategory", "Usage"), ("ChargeDescription", ""), ("ChargeFrequency", ""),
        ("BillingCurrency", "USD"), ("CommitmentDiscountStatus", ""), ("CommitmentDiscountType", ""),
        ("CommitmentDiscountId", ""), ("CommitmentDiscountName", ""), ("PricingCategory", ""), ("ConsumedUnit", ""), ("PricingUnit", ""),
        ("SkuMeter", ""), ("SkuDescription", ""), ("SkuMeterCategory", ""), ("SkuMeterSubcategory", ""),
        ("PublisherName", ""),
    )
    for col, padrao in padroes:
        if col not in df.columns:
            df[col] = padrao
        else:
            df[col] = df[col].fillna(padrao).astype(str)
            if padrao:
                df.loc[df[col].str.strip() == "", col] = padrao

    # Economia so faz sentido quando o preco de lista existe. Quando o Cost Management nao
    # envia ListCost, o toolkit copia o ContractedCost; refletimos a mesma regra.
    sem_lista = df["ListCost"] <= 0
    df.loc[sem_lista, "ListCost"] = df.loc[sem_lista, "ContractedCost"]
    sem_lista = df["ListCost"] <= 0
    df.loc[sem_lista, "ListCost"] = df.loc[sem_lista, "EffectiveCost"]

    # Tags: parse uma vez por string distinta (muitas linhas repetem o mesmo conjunto).
    df["TagsStr"] = df["Tags"].map(_tags_para_texto) if "Tags" in df.columns else ""
    tags_por_string = {s: parse_tags(s) for s in df["TagsStr"].unique()}
    df["SemTag"] = df["TagsStr"].map(lambda s: len(tags_por_string.get(s, {})) == 0)

    # Ambiente: cache por combinacao, porque classificar linha a linha e caro em volume.
    combos = df[["ResourceName", "ResourceGroupName", "SubAccountName", "TagsStr"]].drop_duplicates()
    mapa_amb = {
        (r.ResourceName, r.ResourceGroupName, r.SubAccountName, r.TagsStr):
            classificar_ambiente(r.ResourceName, r.ResourceGroupName, r.SubAccountName, tags_por_string.get(r.TagsStr, {}))
        for r in combos.itertuples(index=False)
    }
    df["Ambiente"] = [
        mapa_amb[(a, b, c, d)]
        for a, b, c, d in zip(df["ResourceName"], df["ResourceGroupName"], df["SubAccountName"], df["TagsStr"])
    ]

    if "Tags" in df.columns:
        df = df.drop(columns=["Tags"])
    return df, tags_por_string


# ============================================================================ base
class FonteBase:
    """Cache, trava e ouvintes. As subclasses implementam apenas _ler()."""

    backend = "base"
    descricao = ""

    def __init__(self):
        self._credencial = None
        self._cache: Carga | None = None
        self._cache_em = 0.0
        self._trava = threading.Lock()
        self.ouvintes_pos_carga: list = []  # funcoes chamadas apos cada carga nova (ex.: avaliar alertas)

    def credencial(self):
        from azure.identity import DefaultAzureCredential

        if self._credencial is None:
            self._credencial = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        return self._credencial

    def _ler(self) -> tuple[pd.DataFrame | None, int, int, str | None]:
        """Devolve (dataframe bruto, quantidade de arquivos ou consultas, bytes lidos, erro)."""
        raise NotImplementedError

    def carregar(self, forcar: bool = False) -> Carga:
        if not forcar and self._cache and (time.time() - self._cache_em) < CACHE_TTL_SEGUNDOS:
            return self._cache

        nova = False
        with self._trava:
            if not forcar and self._cache and (time.time() - self._cache_em) < CACHE_TTL_SEGUNDOS:
                return self._cache

            inicio = time.time()
            carga = Carga(backend=self.backend)
            try:
                bruto, carga.arquivos, carga.bytes_lidos, carga.erro = self._ler()
                if bruto is not None and not bruto.empty:
                    carga.df, carga.tags_por_string = normalizar(bruto)
                    carga.linhas = len(carga.df)
                    carga.meses = sorted(m for m in carga.df["Mes"].unique() if m)
                elif not carga.erro:
                    carga.erro = "A fonte respondeu, mas nao havia linhas de custo."
            except Exception as exc:  # noqa: BLE001
                carga.erro = f"Erro inesperado ao carregar os dados: {exc}"
                log.exception("Erro ao carregar")

            carga.carregado_em = datetime.now(timezone.utc)
            carga.duracao_segundos = round(time.time() - inicio, 2)
            self._cache = carga
            self._cache_em = time.time()
            nova = True
            log.info("Carga (%s): %s linhas, %s fontes, %.2fs", self.backend, carga.linhas, carga.arquivos, carga.duracao_segundos)

        if nova:
            for ouvinte in list(self.ouvintes_pos_carga):
                try:
                    ouvinte(self._cache)
                except Exception:  # noqa: BLE001
                    log.exception("Ouvinte pos-carga falhou")
        return self._cache

    def invalidar(self) -> None:
        self._cache_em = 0.0


# ============================================================================ storage (nivel 0)
class FonteStorage(FonteBase):
    """Le os parquet FOCUS do container ingestion do FinOps hub."""

    backend = "storage"

    def __init__(self, storage_account: str | None = None, storage_url: str | None = None):
        super().__init__()
        self.storage_account = storage_account or os.getenv("HUB_STORAGE_ACCOUNT", "")
        url = storage_url or os.getenv("HUB_STORAGE_URL", "")
        if not url and self.storage_account:
            url = f"https://{self.storage_account}.dfs.core.windows.net"

        # Aceita a raiz ou a URL com /ingestion (o valor que o instalador imprime para o Power BI).
        url = (url or "").rstrip("/")
        if url.endswith(f"/{CONTAINER}"):
            url = url[: -len(CONTAINER) - 1]
        self.storage_url = url

        if not self.storage_url:
            raise ValueError("Informe o storage do hub em HUB_STORAGE_ACCOUNT ou HUB_STORAGE_URL. Exemplo: HUB_STORAGE_ACCOUNT=finopshubabc123")
        if not self.storage_account:
            m = re.match(r"https://([^.]+)\.", self.storage_url)
            self.storage_account = m.group(1) if m else ""
        self.descricao = f"parquet em {self.storage_account}/{CONTAINER}/{PASTA_CUSTOS}"

    def _cliente(self):
        from azure.storage.filedatalake import DataLakeServiceClient

        return DataLakeServiceClient(account_url=self.storage_url, credential=self.credencial())

    @staticmethod
    def _listar_parquet(fs) -> list[tuple[str, int]]:
        return [(c.name, c.content_length or 0) for c in fs.get_paths(path=PASTA_CUSTOS, recursive=True)
                if not c.is_directory and c.name.lower().endswith(".parquet")]

    @staticmethod
    def _ler_parquet(fs, caminho: str) -> pd.DataFrame | None:
        import pyarrow.parquet as pq

        try:
            dados = fs.get_file_client(caminho).download_file().readall()
            tabela = pq.read_table(io.BytesIO(dados))
            manter = [c for c in COLUNAS_DESEJADAS if c in set(tabela.column_names)]
            if manter:
                tabela = tabela.select(manter)
            return tabela.to_pandas()
        except Exception as exc:  # noqa: BLE001
            log.warning("Falha ao ler %s: %s", caminho, exc)
            return None

    def _ler(self):
        from azure.core.exceptions import AzureError

        try:
            fs = self._cliente().get_file_system_client(CONTAINER)
            arquivos = self._listar_parquet(fs)
            total_bytes = sum(t for _, t in arquivos)
            if not arquivos:
                return None, 0, 0, ("Nenhum arquivo parquet encontrado em ingestion/Costs. "
                                    "O hub ainda nao ingeriu dado, ou o export nao entregou.")
            partes = [p for p in (self._ler_parquet(fs, c) for c, _ in arquivos) if p is not None and not p.empty]
            if not partes:
                return None, len(arquivos), total_bytes, "Os arquivos parquet foram encontrados, mas nenhum tinha linhas."
            return pd.concat(partes, ignore_index=True, sort=False), len(arquivos), total_bytes, None
        except AzureError as exc:
            log.exception("Erro de acesso ao storage")
            return None, 0, 0, (f"Nao consegui ler o storage {self.storage_account}: {exc}. "
                                "Confira se a identidade da aplicacao tem o papel Storage Blob Data Reader.")


# Nome historico, mantido para compatibilidade com quem importa FonteDeCustos.
FonteDeCustos = FonteStorage


# ============================================================================ estatica (testes e previa)
class FonteEstatica(FonteBase):
    """Fonte a partir de um dataframe ja montado. Usada nos testes e na previa."""

    backend = "demonstracao"
    descricao = "dados de demonstracao em memoria"

    def __init__(self, df: pd.DataFrame):
        super().__init__()
        self._bruto = df.copy()
        self.storage_account = "demonstracao"
        self.storage_url = "local"

    def _ler(self):
        meses = int(pd.to_datetime(self._bruto["ChargePeriodStart"]).dt.to_period("M").nunique()) if "ChargePeriodStart" in self._bruto else 1
        return self._bruto.copy(), meses, 0, None


# ============================================================================ fabrica
def criar_fonte() -> FonteBase:
    """
    Escolhe a fonte pelas variaveis de ambiente:
      DATA_BACKEND=storage  (padrao)  HUB_STORAGE_ACCOUNT ou HUB_STORAGE_URL
      DATA_BACKEND=kusto              KUSTO_QUERY_URI, KUSTO_DATABASE (padrao Hub), KUSTO_MONTHS (padrao 13)
    """
    backend = os.getenv("DATA_BACKEND", "storage").strip().lower()
    if backend in ("kusto", "fabric", "eventhouse", "adx", "dataexplorer"):
        from kusto_source import FonteKusto

        return FonteKusto()
    return FonteStorage()
