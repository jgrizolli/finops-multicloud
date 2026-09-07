"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Gerador de dados de DEMONSTRACAO no formato FOCUS. Usado pelos testes e pela previa.
Os numeros sao inventados; a estrutura e a mesma do parquet do FinOps hub.
"""

from __future__ import annotations

import json
import random
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd

# (servico, categoria, tipo de recurso, medidor tipico, custo mensal base, unidade de consumo)
SERVICOS = [
    ("Virtual Machines", "Compute", "microsoft.compute/virtualmachines", "D4s v3", 18400, "1 Hour"),
    ("Virtual Machines", "Compute", "microsoft.compute/virtualmachines", "D8s v5", 9200, "1 Hour"),
    ("Azure Kubernetes Service", "Compute", "microsoft.containerservice/managedclusters", "Standard Uptime SLA", 11200, "1 Hour"),
    ("Azure SQL Database", "Databases", "microsoft.sql/servers/databases", "General Purpose vCore", 9800, "1 Hour"),
    ("Azure SQL Database", "Databases", "microsoft.sql/servers/databases", "Business Critical vCore", 4200, "1 Hour"),
    ("Azure Cosmos DB", "Databases", "microsoft.documentdb/databaseaccounts", "Provisioned Throughput RU/s", 3200, "100 RU/s"),
    ("Azure Database for PostgreSQL", "Databases", "microsoft.dbforpostgresql/flexibleservers", "General Purpose vCore", 2700, "1 Hour"),
    ("Azure Cache for Redis", "Databases", "microsoft.cache/redis", "Premium P1", 1300, "1 Hour"),
    ("Storage Accounts", "Storage", "microsoft.storage/storageaccounts", "Hot LRS Data Stored", 4100, "1 GB/Month"),
    ("Storage Accounts", "Storage", "microsoft.storage/storageaccounts", "RA-GRS Data Stored", 2300, "1 GB/Month"),
    ("Storage Accounts", "Storage", "microsoft.compute/disks", "Premium SSD Managed Disks P30", 3600, "1/Month"),
    ("Azure OpenAI Service", "AI and Machine Learning", "microsoft.cognitiveservices/accounts", "gpt-4o Input Tokens", 3900, "1K Tokens"),
    ("Azure OpenAI Service", "AI and Machine Learning", "microsoft.cognitiveservices/accounts", "gpt-4o Output Tokens", 2600, "1K Tokens"),
    ("Azure OpenAI Service", "AI and Machine Learning", "microsoft.cognitiveservices/accounts", "gpt-4 Input Tokens", 1800, "1K Tokens"),
    ("Azure AI Foundry", "AI and Machine Learning", "microsoft.cognitiveservices/accounts", "AI Agent Service Runtime", 1400, "1 Hour"),
    ("Azure AI Search", "AI and Machine Learning", "microsoft.search/searchservices", "Standard S1", 700, "1 Hour"),
    ("API Management", "Integration", "microsoft.apimanagement/service", "Standard v2", 4300, "1 Hour"),
    ("Application Gateway", "Networking", "microsoft.network/applicationgateways", "WAF v2 Capacity Unit", 3800, "1 Hour"),
    ("Load Balancer", "Networking", "microsoft.network/loadbalancers", "Standard Rules", 2100, "1 Hour"),
    ("Virtual Network", "Networking", "microsoft.network/virtualnetworks", "Peering Data Transfer", 1500, "1 GB"),
    ("Azure Data Factory", "Analytics", "microsoft.datafactory/factories", "Data Movement", 1900, "1 DIU Hour"),
    ("Log Analytics", "Analytics", "microsoft.operationalinsights/workspaces", "Pay-as-you-go Data Ingestion", 2600, "1 GB"),
    ("App Service", "Compute", "microsoft.web/serverfarms", "Premium v2 P1 v2", 1700, "1 Hour"),
    ("Azure Container Registry", "Compute", "microsoft.containerregistry/registries", "Premium Registry Unit", 900, "1 Day"),
    ("Microsoft Defender for Cloud", "Security", "microsoft.security/pricings", "Standard Node", 700, "1 Node/Month"),
    ("Key Vault", "Security", "microsoft.keyvault/vaults", "Operations", 120, "10K"),
]

AWS = [
    ("Amazon EC2", "Compute", "AWS::EC2::Instance", "m5.xlarge", 7200, "Hrs"),
    ("Amazon RDS", "Databases", "AWS::RDS::DBInstance", "db.r5.large PostgreSQL", 3900, "Hrs"),
    ("Amazon DynamoDB", "Databases", "AWS::DynamoDB::Table", "Provisioned WCU", 1100, "WCU-Hrs"),
    ("Amazon S3", "Storage", "AWS::S3::Bucket", "Standard Storage", 1800, "GB-Mo"),
    ("Amazon EBS", "Storage", "AWS::EC2::Volume", "gp2 Volume", 1400, "GB-Mo"),
    ("Amazon Bedrock", "AI and Machine Learning", "AWS::Bedrock::Model", "Claude 3.5 Sonnet Input Tokens", 1600, "1K Tokens"),
    ("Amazon ElastiCache", "Databases", "AWS::ElastiCache::Cluster", "cache.r6g.large", 900, "Hrs"),
]
GOOGLE = [
    ("Compute Engine", "Compute", "compute.googleapis.com/Instance", "n1-standard-4", 2800, "hour"),
    ("Cloud SQL", "Databases", "sqladmin.googleapis.com/Instance", "db-custom-4-16384", 1500, "hour"),
    ("BigQuery", "Analytics", "bigquery.googleapis.com/Dataset", "Analysis", 1100, "TiB"),
    ("Vertex AI", "AI and Machine Learning", "aiplatform.googleapis.com/Endpoint", "Gemini 1.5 Pro Input Tokens", 900, "1K Tokens"),
    ("Cloud Storage", "Storage", "storage.googleapis.com/Bucket", "Standard Storage", 600, "GiB-month"),
]
OCI = [
    ("Compute", "Compute", "oci.compute/instance", "VM.Standard.E4.Flex OCPU", 1900, "OCPU Hours"),
    ("Autonomous Database", "Databases", "oci.database/autonomousdatabase", "OCPU Per Hour", 2200, "OCPU Hours"),
    ("Block Volume", "Storage", "oci.blockstorage/volume", "Higher Performance", 500, "GB Months"),
    ("Generative AI", "AI and Machine Learning", "oci.generativeai/endpoint", "Cohere Command R Tokens", 400, "10K Transactions"),
]

NUVENS = [("Microsoft Azure", SERVICOS, 1.0, ["sub-prod-core", "sub-prod-data", "sub-dev-test", "sub-shared-svc"], 0.0),
          ("Amazon Web Services", AWS, 1.0, ["aws-prod-platform", "aws-analytics"], 0.62),
          ("Google Cloud", GOOGLE, 1.0, ["gcp-data-platform"], 0.45),
          ("Oracle Cloud", OCI, 1.0, ["oci-erp-prod"], 0.35)]

REGIOES = ["brazilsouth", "eastus", "westeurope", "southcentralus", "northeurope", "Global"]
GRUPOS = ["rg-prod-core", "rg-prod-data", "rg-plataforma", "rg-dev-app", "rg-test-api", "rg-hml-erp", "rg-observabilidade", "rg-finops-hub", "rg-legado-disks", ""]
CONTAS = {"Microsoft Azure": "Contrato Enterprise", "Amazon Web Services": "Conta pagadora AWS", "Google Cloud": "Billing account GCP", "Oracle Cloud": "Tenancy Oracle"}
CENTROS = ["CC-1001", "CC-2002", "CC-3003", "CC-4004"]
TIMES = ["plataforma", "dados", "canais", "erp"]


def gerar(dias: int = 400, semente: int = 11) -> pd.DataFrame:
    random.seed(semente)
    np.random.seed(semente)
    hoje = datetime.now(timezone.utc).date()
    linhas = []
    for d in range(dias, -1, -1):
        dia = hoje - timedelta(days=d)
        decorrido = (dias - d) / dias
        tendencia = 1 + decorrido * 0.30
        semana = 0.82 if dia.weekday() >= 5 else 1.0
        pico = 2.6 if 33 <= d <= 35 else 1.0

        for nuvem, catalogo, peso, contas, inicio in NUVENS:
            if d > dias * (1 - inicio):
                continue
            for servico, categoria, tipo, medidor, base_mensal, unidade in catalogo:
                acel = 1 + decorrido * 2.4 if "OpenAI" in servico or "Bedrock" in servico or "Vertex" in servico else 1.0
                diario = base_mensal / 30.0 * peso * tendencia * semana * pico * acel
                for _ in range(random.randint(1, 3)):
                    valor = diario / 2.2 * random.uniform(0.7, 1.3)
                    if valor <= 0:
                        continue
                    grupo = random.choice(GRUPOS)
                    # grupo legado so tem disco: exercita a regra de "sobra"
                    if grupo == "rg-legado-disks" and "disk" not in tipo.lower() and "Storage" not in servico:
                        grupo = "rg-prod-core"
                    nao_prod = any(k in grupo for k in ("dev", "test", "hml"))
                    if nao_prod:
                        semana_np = 1.0  # dev ligado no fim de semana, exercita a regra de agendamento
                        valor *= semana_np / semana
                    comprometido = servico in ("Virtual Machines", "Azure SQL Database", "Amazon RDS", "Amazon EC2") and random.random() < 0.42
                    desconto = random.uniform(0.55, 0.72) if comprometido else random.uniform(0.88, 1.0)
                    tags = {}
                    if random.random() > 0.34:
                        tags = {"CostCenter": random.choice(CENTROS), "Owner": f"{random.choice(TIMES)}@empresa.com",
                                "Environment": "dev" if nao_prod else "prod"}
                        if random.random() < 0.3:
                            tags.pop("Owner")
                    eh_token = "Token" in medidor
                    quantidade = random.uniform(200, 9000) if eh_token else random.uniform(1, 120)
                    linhas.append({
                        "BilledCost": round(valor, 6), "EffectiveCost": round(valor, 6), "ListCost": round(valor / desconto, 6),
                        "ContractedCost": round(valor * random.uniform(0.97, 1.0), 6), "BillingCurrency": "USD",
                        "ChargePeriodStart": pd.Timestamp(dia), "ChargePeriodEnd": pd.Timestamp(dia + timedelta(days=1)),
                        "ChargeCategory": "Purchase" if (comprometido and dia.day == 1 and random.random() < 0.2) else "Usage",
                        "ChargeDescription": f"{servico} {medidor}", "ServiceName": servico, "ServiceCategory": categoria,
                        "ResourceType": tipo, "ResourceName": f"{servico.split()[0][:8].lower()}-{random.randint(1, 40):03d}",
                        "ResourceId": f"/subscriptions/x/resourceGroups/{grupo}/providers/{tipo}/{servico[:6].lower()}-{random.randint(1, 40):03d}",
                        "RegionName": random.choice(REGIOES), "SubAccountName": random.choice(contas), "BillingAccountName": CONTAS[nuvem],
                        "x_ResourceGroupName": grupo, "x_SourceProvider": nuvem, "ProviderName": nuvem,
                        "CommitmentDiscountId": f"res-{random.randint(1, 6):02d}" if comprometido else None,
                        "CommitmentDiscountName": f"Reserva {servico[:12]} {random.randint(1, 6):02d}" if comprometido else None,
                        "CommitmentDiscountStatus": ("Unused" if random.random() < 0.12 else "Used") if comprometido else "",
                        "PricingCategory": "Committed" if comprometido else "On-Demand",
                        "ConsumedQuantity": round(quantidade, 3), "ConsumedUnit": unidade, "PricingQuantity": round(quantidade, 3), "PricingUnit": unidade,
                        "x_SkuMeterName": medidor, "x_SkuDescription": f"{servico} {medidor}",
                        "Tags": json.dumps(tags) if tags else "{}",
                    })
    return pd.DataFrame(linhas)


CENTROS_DEMO = [
    {"id": "cc-plataforma", "nome": "Plataforma", "responsavel": "Ana Souza", "email": "ana.souza@empresa.com", "orcamentoMensal": 45000,
     "regras": [{"tipo": "tag", "chave": "CostCenter", "valor": "CC-1001"}, {"tipo": "grupo", "valor": "rg-plataforma"}]},
    {"id": "cc-dados", "nome": "Dados e Analytics", "responsavel": "João Lima", "email": "joao.lima@empresa.com", "orcamentoMensal": 30000,
     "regras": [{"tipo": "tag", "chave": "CostCenter", "valor": "CC-2002"}, {"tipo": "assinatura", "valor": "sub-prod-data"}, {"tipo": "assinatura", "valor": "aws-analytics"}]},
    {"id": "cc-canais", "nome": "Canais Digitais", "responsavel": "Carla Reis", "email": "carla.reis@empresa.com", "orcamentoMensal": 25000,
     "regras": [{"tipo": "tag", "chave": "CostCenter", "valor": "CC-3003"}]},
    {"id": "cc-erp", "nome": "ERP Corporativo", "responsavel": "Marcos Dias", "email": "marcos.dias@empresa.com", "orcamentoMensal": 20000,
     "regras": [{"tipo": "tag", "chave": "CostCenter", "valor": "CC-4004"}, {"tipo": "nuvem", "valor": "Oracle Cloud"}]},
]

ORCAMENTOS_DEMO = [
    {"id": "orc-total", "nome": "Orçamento total mensal", "escopoTipo": "total", "valorMensal": 120000},
    {"id": "orc-cc1001", "nome": "CC-1001 Plataforma", "escopoTipo": "tag", "chave": "CostCenter", "valor": "CC-1001", "valorMensal": 45000},
    {"id": "orc-cc2002", "nome": "CC-2002 Dados", "escopoTipo": "tag", "chave": "CostCenter", "valor": "CC-2002", "valorMensal": 30000},
    {"id": "orc-ia", "nome": "IA generativa", "escopoTipo": "servico", "valor": "Azure OpenAI Service", "valorMensal": 9000},
]
