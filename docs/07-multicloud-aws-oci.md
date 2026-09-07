# Multicloud: o que preparar na AWS e na OCI

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [12. O que preparar na AWS e na OCI](#12-o-que-preparar-na-aws-e-na-oci)

---

## 12. O que preparar na AWS e na OCI

**AWS (conta pagadora, região us-east-1)**: `aws/README-aws.md`. Em resumo: CloudFormation `aws/focus-export-cloudformation.yaml`
(bucket com policy, Data Export FOCUS 1.0 em parquet diário com overwrite, export do Cost Optimization Hub, usuário IAM de leitura),
depois gerar o access key do usuário `finops-hub-s3-reader`.

```bash
# alternativa por linha de comando, na conta pagadora
aws cloudformation deploy --region us-east-1 --stack-name finops-focus-export \
  --template-file aws/focus-export-cloudformation.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides BucketName=finops-focus-exports-123456789012 S3Prefix=focus FocusExportName=finops-focus-1-0
aws iam create-access-key --user-name finops-hub-s3-reader
```

**OCI (tenancy)**: `oci/README-oci.md`. Em resumo: grupo `finops-readers`, policy com
`endorse group finops-readers to read objects in tenancy usage-report` (mais a linha `define tenancy usage-report ...` publicada pela
Oracle), usuário `finops-hub-reader` com API key; anote OCID da tenancy, OCID do usuário, fingerprint e região home.
