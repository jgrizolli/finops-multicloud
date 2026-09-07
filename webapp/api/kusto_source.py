"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Fonte de dados para o nivel 1: Eventhouse do Microsoft Fabric ou Azure Data Explorer.

Quando o FinOps hub e implantado com Fabric ou Data Explorer, o dado nao fica so no parquet:
ele e ingerido no banco "Hub", onde as funcoes Costs(), Costs_v1_0() e Costs_v1_2() entregam
o FOCUS ja convertido para a versao mais nova e com colunas extras do hub (x_SourceProvider,
x_SourceName, x_IngestionTime). E isso que esta fonte consulta.

Por que existe:
  o parquet em storage funciona muito bem ate alguns milhoes de linhas por mes. Acima disso,
  o Kusto agrega em segundos o que o pandas levaria minutos para carregar. A troca e feita
  por variavel de ambiente e a interface nao percebe: o dataframe que sai daqui e identico
  ao que sai do storage, porque passa pela mesma normalizacao.

Permissao:
  a identidade da aplicacao precisa ser viewer do banco Hub:
      .add database Hub viewers ('aadapp=<principalId-da-aplicacao>;<tenantId>')
  No Fabric, isso se faz no Eventhouse > banco Hub > Manage > Permissions, ou pelo comando
  acima na janela de consulta.

Escala:
  a consulta abaixo traz linhas. Para estates realmente grandes, o proximo passo e mover as
  agregacoes das paginas para KQL (summarize no servidor) e devolver so os resultados. O
  contrato da API nao muda, entao o front continua igual.
"""

from __future__ import annotations

import logging
import os

import pandas as pd

from data_source import COLUNAS_DESEJADAS, FonteBase

log = logging.getLogger("finops.kusto")

# Colunas que existem nas funcoes Costs* do hub. As demais de COLUNAS_DESEJADAS sao variantes
# de nome do FOCUS 1.0 que o Kusto ja converteu, entao nao precisam ser pedidas.
COLUNAS_KUSTO = [c for c in COLUNAS_DESEJADAS if c not in ("x_SkuMeterName", "SkuMeterName", "x_ResourceGroupName")] + ["x_ResourceGroupName", "x_SourceName", "x_IngestionTime"]


def montar_consulta(funcao: str, meses: int, colunas: list[str] | None = None) -> str:
    """
    KQL que a fonte executa. Fica em funcao separada para ser testavel sem Kusto.

    - set notruncation: o Kusto corta em 500 mil linhas por padrao; aqui queremos tudo do periodo.
    - project-keep com as colunas desejadas, tolerando as que nao existirem naquela versao.
    """
    colunas = colunas or COLUNAS_KUSTO
    return (
        "set notruncation;\n"
        f"{funcao}\n"
        f"| where ChargePeriodStart >= startofmonth(now(), -{max(int(meses) - 1, 0)})\n"
        f"| project-keep {', '.join(colunas)}"
    )


class FonteKusto(FonteBase):
    """Consulta o banco Hub e devolve o mesmo dataframe da fonte de storage."""

    backend = "kusto"

    def __init__(self, query_uri: str | None = None, database: str | None = None, funcao: str | None = None, meses: int | None = None):
        super().__init__()
        self.query_uri = (query_uri or os.getenv("KUSTO_QUERY_URI", "")).strip().rstrip("/")
        self.database = (database or os.getenv("KUSTO_DATABASE", "Hub")).strip()
        # Costs() e a funcao "sempre na versao mais nova". Costs_v1_2() fixa a versao e e mais
        # previsivel quando o toolkit evolui. Escolha pela variavel KUSTO_FUNCTION.
        self.funcao = (funcao or os.getenv("KUSTO_FUNCTION", "Costs()")).strip()
        self.meses = int(meses or os.getenv("KUSTO_MONTHS", "13"))
        if not self.query_uri:
            raise ValueError("Informe KUSTO_QUERY_URI (Eventhouse > System overview > Query URI, ou URI do cluster Data Explorer).")
        self.storage_account = self.query_uri.replace("https://", "").split(".")[0]
        self.storage_url = self.query_uri
        self.descricao = f"KQL {self.funcao} no banco {self.database} em {self.query_uri}"

    def _cliente(self):
        from azure.kusto.data import KustoClient, KustoConnectionStringBuilder

        kcsb = KustoConnectionStringBuilder.with_azure_token_credential(self.query_uri, self.credencial())
        return KustoClient(kcsb)

    def _ler(self):
        from azure.kusto.data.exceptions import KustoServiceError
        from azure.kusto.data.helpers import dataframe_from_result_table

        consulta = montar_consulta(self.funcao, self.meses)
        try:
            with self._cliente() as cliente:
                resposta = cliente.execute(self.database, consulta)
            df = dataframe_from_result_table(resposta.primary_results[0])
            if df.empty:
                return None, 1, 0, f"A consulta {self.funcao} no banco {self.database} nao devolveu linhas para os ultimos {self.meses} meses."
            # o Kusto devolve Tags como dict; a normalizacao trata os dois formatos
            return df, 1, int(df.memory_usage(deep=True).sum()), None
        except KustoServiceError as exc:
            log.exception("Erro no Kusto")
            msg = str(exc)
            if "Forbidden" in msg or "401" in msg or "403" in msg:
                dica = (" Conceda a identidade da aplicacao o papel de viewer no banco: "
                        ".add database Hub viewers ('aadapp=<principalId>;<tenantId>')")
            elif "SEM0100" in msg or "not found" in msg.lower():
                dica = f" A funcao {self.funcao} nao existe no banco {self.database}. Confira KUSTO_FUNCTION e KUSTO_DATABASE."
            else:
                dica = ""
            return None, 0, 0, f"Nao consegui consultar o Kusto em {self.query_uri}: {msg}.{dica}"
        except Exception as exc:  # noqa: BLE001
            log.exception("Erro inesperado no Kusto")
            return None, 0, 0, f"Erro ao consultar o Kusto: {exc}"
