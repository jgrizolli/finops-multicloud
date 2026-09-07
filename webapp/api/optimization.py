"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Otimizacao: onde da para economizar, a partir do que o FOCUS revela.

Cada regra devolve recomendacoes com: recurso ou servico, o que esta em uso, o que trocar,
custo atual no periodo, economia estimada (uma faixa, porque e estimativa) e confianca.
Os percentuais de economia sao aproximacoes publicas de mercado e estao declarados em cada
regra. Servem para priorizar, nao para fechar orcamento.

Importante: o FOCUS mostra o que foi cobrado, nao a utilizacao. Por isso nao ha aqui
"VM ociosa por CPU baixa". Isso vem do Azure Advisor, que o hub tambem ingere quando a
opcao de recomendacoes esta ligada, e sera integrado nesta pagina.
"""

from __future__ import annotations

import re

import numpy as np
import pandas as pd

import analytics
from data_source import PADRAO_NAO_PROD  # noqa: F401  (mantido para referencia)


def _rec(categoria, titulo, atual, sugerido, custo, pct_min, pct_max, confianca, acao, recurso="", servico="", nuvem="", quantidade=1):
    return {
        "categoria": categoria, "titulo": titulo, "atual": atual, "sugerido": sugerido,
        "recurso": recurso, "servico": servico, "nuvem": nuvem, "quantidade": int(quantidade),
        "custoAtual": float(custo), "economiaMin": float(custo * pct_min), "economiaMax": float(custo * pct_max),
        "economiaEstimada": float(custo * (pct_min + pct_max) / 2), "confianca": confianca, "acao": acao,
    }


# ------------------------------------------------------------------ 1. compromissos
def _compromissos_ociosos(df):
    ocioso = df[df["CommitmentDiscountStatus"].str.lower() == "unused"]
    if ocioso.empty:
        return []
    saida = []
    for (nome, nuvem), g in ocioso.groupby(["CommitmentDiscountName", "Nuvem"]):
        custo = float(g["EffectiveCost"].sum())
        if custo <= 0:
            continue
        saida.append(_rec("Compromissos", "Reserva ou savings plan sem uso", nome or "compromisso",
                          "Trocar escopo, trocar família ou devolver", custo, 0.9, 1.0, "alta",
                          "Reveja o escopo (single vs shared) e a família. No Azure, troca e reembolso parcial são possíveis.",
                          recurso=nome, servico="Compromisso", nuvem=nuvem))
    return saida


def _oportunidade_compromisso(df):
    """Servicos elegiveis com gasto sob demanda estavel nos ultimos 30 dias."""
    elegiveis = re.compile(r"virtual machines|compute|sql|cosmos|app service|redis|postgresql|mysql|synapse|databricks|"
                           r"ec2|rds|dynamodb|elasticache|compute engine|cloud sql", re.I)
    corte = analytics.hoje() - pd.Timedelta(days=30)
    rec = df[(df["Data"] >= corte) & (df["CommitmentDiscountId"].str.strip() == "") &
             (df["ChargeCategory"] == "Usage") & df["ServiceName"].str.contains(elegiveis, na=False)]
    if rec.empty:
        return []
    saida = []
    for (servico, nuvem), g in rec.groupby(["ServiceName", "Nuvem"]):
        diario = g.groupby(g["Data"].dt.date)["EffectiveCost"].sum()
        if len(diario) < 20:
            continue
        media, cv = float(diario.mean()), float(diario.std() / diario.mean()) if diario.mean() > 0 else 9
        mensal = media * 30
        if mensal < 50 or cv > 0.35:
            continue
        conf = "alta" if cv < 0.15 else "média"
        saida.append(_rec("Compromissos", "Gasto estável sem compromisso", f"{servico} sob demanda",
                          "Reserva de 1 ou 3 anos, ou savings plan", mensal, 0.25, 0.45, conf,
                          f"Uso constante nos últimos 30 dias (variação de {cv:.0%}). Simule uma reserva para a base estável.",
                          servico=servico, nuvem=nuvem))
    return saida


# ------------------------------------------------------------------ 2. horario
def _fim_de_semana(df):
    """Nao producao que custa igual no fim de semana: candidata a desligamento programado."""
    compute = re.compile(r"virtual machines|app service|kubernetes|compute|databricks|synapse|ec2|eks|compute engine|gke", re.I)
    rec = df[(df["Ambiente"] == "Não produção") & df["ServiceName"].str.contains(compute, na=False)]
    if rec.empty:
        return []
    saida = []
    for (grupo, nuvem), g in rec.groupby(["ResourceGroupName", "Nuvem"]):
        diario = g.groupby(g["Data"].dt.date)["EffectiveCost"].sum()
        if len(diario) < 14:
            continue
        idx = pd.to_datetime(pd.Series(diario.index))
        fds = diario.values[(idx.dt.dayofweek >= 5).values]
        uteis = diario.values[(idx.dt.dayofweek < 5).values]
        if len(fds) < 2 or len(uteis) < 5 or uteis.mean() <= 0:
            continue
        razao = fds.mean() / uteis.mean()
        if razao < 0.7:
            continue  # ja desliga
        custo_periodo = float(g["EffectiveCost"].sum())
        # desligar noites e fins de semana costuma cortar 60% a 70% das horas
        saida.append(_rec("Agendamento", "Não produção ligada 24x7", f"{grupo or 'grupo sem nome'} (fim de semana custa {razao:.0%} do dia útil)",
                          "Auto-shutdown fora do horário comercial", custo_periodo, 0.45, 0.65, "média",
                          "Aplique Start/Stop programado (Azure Automation, Instance Scheduler na AWS). Ambientes de dev raramente precisam rodar à noite.",
                          recurso=grupo, servico="Compute", nuvem=nuvem))
    return saida


# ------------------------------------------------------------------ 3. troca de tecnologia
REGRAS_TROCA = [
    # (regex no texto, nuvem opcional, so nao-prod?, atual, sugerido, pct_min, pct_max, confianca, acao)
    (re.compile(r"premium ssd managed disks|\bP(10|15|20|30|40|50)\b.*disk", re.I), "Microsoft Azure", True,
     "Premium SSD em não produção", "Standard SSD (ou Premium SSD v2)", 0.40, 0.60, "média",
     "Disco Premium em ambiente de dev raramente se justifica. Standard SSD atende a maior parte dos casos."),
    (re.compile(r"\b[DE]\d+a?s? v[23]\b|\bA\d+ v2\b|\bDv2\b|\bDv3\b|\bEv3\b", re.I), "Microsoft Azure", False,
     "VM de geração antiga (v2/v3)", "Série v5 ou v6 equivalente (Dsv5, Dasv5, Dlsv5)", 0.10, 0.25, "alta",
     "As séries v5 têm melhor preço por desempenho. Dasv5 (AMD) costuma ficar 10% a 15% abaixo de Dsv5."),
    (re.compile(r"\bD\d+s? v5\b|\bE\d+s? v5\b", re.I), "Microsoft Azure", False,
     "VM Intel v5", "Equivalente AMD (Dasv5/Easv5) ou Arm (Dpsv5)", 0.10, 0.20, "média",
     "Mesma família, outro processador. AMD reduz cerca de 10%; Arm (Ampere) chega a 20% em cargas compatíveis."),
    (re.compile(r"hot.*(lrs|grs|zrs).*data stored|data stored.*hot", re.I), "Microsoft Azure", False,
     "Blob em camada Hot", "Cool para acesso raro, Archive para retenção", 0.45, 0.80, "média",
     "Dados que não são lidos há mais de 30 dias custam metade em Cool. Configure ciclo de vida por idade."),
    (re.compile(r"\bRA-?GRS\b|\bGRS\b|GZRS", re.I), "Microsoft Azure", True,
     "Replicação geográfica em não produção", "LRS ou ZRS", 0.40, 0.55, "alta",
     "GRS dobra a cópia em outra região. Em dev/test isso não protege nada e custa o dobro."),
    (re.compile(r"sql database.*vcore|vcore.*sql database|general purpose.*vcore", re.I), "Microsoft Azure", True,
     "Azure SQL provisionado em não produção", "Modelo serverless com auto-pause", 0.40, 0.70, "média",
     "Serverless cobra por segundo de uso e pausa quando ocioso. Ideal para dev que fica horas sem consulta."),
    (re.compile(r"business critical", re.I), "Microsoft Azure", True,
     "Azure SQL Business Critical em não produção", "General Purpose", 0.50, 0.65, "alta",
     "Business Critical tem réplicas e SSD local. Fora de produção, General Purpose entrega o mesmo para testes."),
    (re.compile(r"cosmos.*provisioned|provisioned throughput", re.I), "Microsoft Azure", True,
     "Cosmos DB com throughput provisionado em não produção", "Serverless ou autoscale", 0.30, 0.60, "média",
     "Throughput provisionado cobra o teto o tempo todo. Autoscale acompanha o uso e serverless paga por operação."),
    (re.compile(r"premium v2|\bP[123] v2\b", re.I), "Microsoft Azure", False,
     "App Service Premium v2", "Premium v3 (Pv3)", 0.15, 0.25, "alta",
     "Pv3 tem mais memória e custa menos por unidade de capacidade. A migração é uma troca de plano."),
    (re.compile(r"log analytics.*data ingestion|data ingestion.*log analytics|pay-as-you-go.*ingestion", re.I), "Microsoft Azure", False,
     "Log Analytics por GB ingerido", "Commitment tier (100 GB/dia ou mais)", 0.15, 0.30, "média",
     "Acima de ~100 GB/dia, o commitment tier fica 15% a 30% mais barato. Revise também a retenção e as tabelas basic."),
    (re.compile(r"gpt-?4(?!o|\.1)|gpt-4-32k", re.I), "Microsoft Azure", False,
     "GPT-4 (geração anterior)", "GPT-4o ou GPT-4.1 mini para tarefas não críticas", 0.50, 0.85, "média",
     "GPT-4o e os modelos mini custam uma fração do GPT-4 com qualidade comparável na maioria das tarefas. Avalie por caso de uso."),
    (re.compile(r"\bgp2\b", re.I), "Amazon Web Services", False,
     "Volumes EBS gp2", "gp3", 0.18, 0.22, "alta",
     "gp3 é 20% mais barato que gp2 e desacopla IOPS de tamanho. A migração é online."),
    (re.compile(r"\b[mcr][56][a-z]?\.(large|xlarge|\d+xlarge)\b", re.I), "Amazon Web Services", False,
     "EC2 Intel (m5/c5/r5)", "Graviton (m7g/c7g/r7g)", 0.15, 0.25, "média",
     "Graviton entrega até 40% melhor preço por desempenho. Exige binários compatíveis com Arm."),
    (re.compile(r"\bio1\b", re.I), "Amazon Web Services", False,
     "Volumes EBS io1", "io2 ou gp3", 0.20, 0.50, "alta",
     "io2 custa o mesmo com mais durabilidade; gp3 atende a maioria dos casos que hoje usam io1."),
    (re.compile(r"\bn1-(standard|highmem|highcpu)", re.I), "Google Cloud", False,
     "Compute Engine N1", "E2 ou N2D", 0.15, 0.30, "alta",
     "N1 é a geração mais antiga ainda cobrada. E2 e N2D são mais baratos e mais rápidos."),
    (re.compile(r"pd-standard|standard persistent disk", re.I), "Google Cloud", False,
     "Persistent Disk Standard em uso ativo", "Balanced PD ou Hyperdisk", 0.0, 0.20, "baixa",
     "Se o disco tem IO relevante, Balanced PD entrega mais por preço similar. Confirme o padrão de uso."),
    (re.compile(r"block volume.*(higher|ultra) performance", re.I), "Oracle Cloud", True,
     "Block Volume de alta performance em não produção", "Balanced", 0.30, 0.50, "média",
     "Volumes Balanced atendem dev/test. Alta performance só para produção com IOPS comprovado."),
]


def _troca_tecnologia(df):
    texto = (df["SkuMeter"] + " | " + df["SkuDescription"] + " | " + df["ChargeDescription"] + " | " + df["ResourceType"])
    saida = []
    for padrao, nuvem, so_nao_prod, atual, sugerido, pmin, pmax, conf, acao in REGRAS_TROCA:
        m = texto.str.contains(padrao, na=False)
        if nuvem:
            m = m & (df["Nuvem"] == nuvem)
        if so_nao_prod:
            m = m & (df["Ambiente"] == "Não produção")
        rec = df[m]
        if rec.empty:
            continue
        custo = float(rec["EffectiveCost"].sum())
        if custo < 5:
            continue
        recursos = rec.loc[rec["ResourceName"].str.strip() != "", "ResourceName"].nunique()
        top = rec.groupby("ResourceName")["EffectiveCost"].sum().sort_values(ascending=False)
        exemplo = str(top.index[0]) if len(top) else ""
        saida.append(_rec("Troca de tecnologia", atual, atual, sugerido, custo, pmin, pmax, conf, acao,
                          recurso=exemplo if recursos == 1 else f"{recursos} recursos (ex.: {exemplo})",
                          servico=str(rec["ServiceName"].mode().iloc[0]) if len(rec) else "", nuvem=nuvem or str(rec["Nuvem"].mode().iloc[0]),
                          quantidade=max(recursos, 1)))
    return saida


# ------------------------------------------------------------------ 4. possiveis sobras
def _sobras(df):
    """Grupos de recurso onde so sobrou storage, disco ou IP, sem nenhum compute. Cheiro de ambiente apagado pela metade."""
    corte = analytics.hoje() - pd.Timedelta(days=30)
    rec = df[(df["Data"] >= corte) & (df["ResourceGroupName"].str.strip() != "")]
    if rec.empty:
        return []
    compute = re.compile(r"virtual machines|kubernetes|app service|functions|container|compute|sql|cosmos|database|redis|ec2|rds|lambda", re.I)
    residual = re.compile(r"storage|disk|public ip|snapshot|network watcher|dns|load balancer|bandwidth", re.I)
    saida = []
    for (grupo, nuvem), g in rec.groupby(["ResourceGroupName", "Nuvem"]):
        servicos = g["ServiceName"].unique()
        tem_compute = any(compute.search(s) for s in servicos)
        so_residual = all(residual.search(s) for s in servicos)
        custo = float(g["EffectiveCost"].sum())
        if tem_compute or not so_residual or custo < 10:
            continue
        saida.append(_rec("Possível sobra", "Grupo só com storage, disco ou IP", f"{grupo}: {', '.join(sorted(servicos)[:4])}",
                          "Confirmar e remover o que sobrou", custo, 0.7, 1.0, "baixa",
                          "Nenhum recurso de computação cobrando no grupo há 30 dias. Discos não anexados, IPs e snapshots costumam ficar para trás.",
                          recurso=grupo, servico="Residual", nuvem=nuvem))
    return saida


# ------------------------------------------------------------------ 5. cauda longa e dev caro
def _dev_caro(df):
    total = float(df["EffectiveCost"].sum())
    if total <= 0:
        return []
    nao_prod = float(df.loc[df["Ambiente"] == "Não produção", "EffectiveCost"].sum())
    pct = nao_prod / total
    if pct < 0.30:
        return []
    return [_rec("Ambientes", "Não produção pesa demais", f"{pct:.0%} do gasto está em ambientes não produtivos",
                 "Política de tamanho e horário para dev/test", nao_prod, 0.20, 0.40, "média",
                 "Referência de mercado: não produção entre 15% e 25% do total. Combine auto-shutdown, SKUs menores e limpeza de ambientes antigos.")]


# ------------------------------------------------------------------ tabela de equivalencias
EQUIVALENCIAS = [
    {"categoria": "Computação", "azure": "Virtual Machines (Dsv5)", "aws": "EC2 (m6i)", "google": "Compute Engine (n2)", "oci": "Compute (VM.Standard3)",
     "dica": "Nas quatro nuvens, a versão AMD ou Arm da mesma família costuma sair 10% a 20% mais barata."},
    {"categoria": "Computação", "azure": "AKS", "aws": "EKS", "google": "GKE", "oci": "OKE",
     "dica": "O plano de controle é barato ou gratuito; o custo está nos nós. Use node pools spot para cargas tolerantes."},
    {"categoria": "Serverless", "azure": "Functions / Container Apps", "aws": "Lambda / Fargate", "google": "Cloud Functions / Cloud Run", "oci": "Functions",
     "dica": "Escala a zero. Para carga contínua acima de 60% do tempo, uma VM reservada fica mais barata."},
    {"categoria": "Banco relacional", "azure": "Azure SQL / PostgreSQL Flexible", "aws": "RDS / Aurora", "google": "Cloud SQL / AlloyDB", "oci": "Autonomous / MySQL HeatWave",
     "dica": "Serverless em dev, reserva em produção. Business Critical e Multi-AZ só onde há SLA que justifique."},
    {"categoria": "NoSQL", "azure": "Cosmos DB", "aws": "DynamoDB", "google": "Firestore / Bigtable", "oci": "NoSQL Database",
     "dica": "Autoscale ou modo por requisição em cargas irregulares; provisionado só com uso estável e alto."},
    {"categoria": "Cache", "azure": "Cache for Redis", "aws": "ElastiCache", "google": "Memorystore", "oci": "Cache with Redis",
     "dica": "Cache em dev raramente precisa de réplica. Tier Basic ou nó único resolve."},
    {"categoria": "Objeto", "azure": "Blob Storage", "aws": "S3", "google": "Cloud Storage", "oci": "Object Storage",
     "dica": "Camadas por idade (Hot, Cool, Archive) com ciclo de vida automático. É a economia mais fácil que existe."},
    {"categoria": "Analítico", "azure": "Fabric / Synapse / Data Explorer", "aws": "Redshift / Athena", "google": "BigQuery", "oci": "Autonomous Data Warehouse",
     "dica": "Pause quando ocioso. Modelos por consulta (Athena, BigQuery on-demand) vencem em uso esporádico."},
    {"categoria": "IA generativa", "azure": "Azure OpenAI / AI Foundry", "aws": "Bedrock", "google": "Vertex AI (Gemini)", "oci": "Generative AI",
     "dica": "Modelos mini ou flash para classificação, extração e resumo. Reserve os modelos grandes para raciocínio complexo."},
    {"categoria": "Observabilidade", "azure": "Log Analytics / App Insights", "aws": "CloudWatch", "google": "Cloud Logging", "oci": "Logging Analytics",
     "dica": "Ingestão é o custo. Filtre na origem, use tabelas basic e reduza a retenção do que ninguém consulta."},
]


def analisar(df, limite: int = 60) -> dict:
    if df.empty:
        return {"resumo": {}, "recomendacoes": [], "porCategoria": [], "equivalencias": EQUIVALENCIAS}
    recs = []
    for regra in (_compromissos_ociosos, _oportunidade_compromisso, _fim_de_semana, _troca_tecnologia, _sobras, _dev_caro):
        try:
            recs.extend(regra(df))
        except Exception:  # noqa: BLE001, uma regra que falha nao derruba as outras
            continue
    recs.sort(key=lambda r: -r["economiaEstimada"])
    recs = recs[:limite]

    total = float(df["EffectiveCost"].sum())
    economia = sum(r["economiaEstimada"] for r in recs)
    por_cat = {}
    for r in recs:
        c = por_cat.setdefault(r["categoria"], {"nome": r["categoria"], "efetivo": 0.0, "quantidade": 0})
        c["efetivo"] += r["economiaEstimada"]
        c["quantidade"] += 1
    por_conf = {"alta": 0.0, "média": 0.0, "baixa": 0.0}
    for r in recs:
        por_conf[r["confianca"]] = por_conf.get(r["confianca"], 0.0) + r["economiaEstimada"]

    return {
        "resumo": {"total": total, "economiaEstimada": economia, "economiaMin": sum(r["economiaMin"] for r in recs),
                   "economiaMax": sum(r["economiaMax"] for r in recs), "percentual": (economia / total) if total else 0.0,
                   "recomendacoes": len(recs), "altaConfianca": por_conf.get("alta", 0.0), "moeda": analytics.moeda_de(df)},
        "recomendacoes": recs, "porCategoria": sorted(por_cat.values(), key=lambda c: -c["efetivo"]),
        "porConfianca": [{"nome": k, "efetivo": v} for k, v in por_conf.items() if v > 0],
        "equivalencias": EQUIVALENCIAS,
    }
