# Imagem da interface web do FinOps Multicloud.
# Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer. Baseado no Microsoft FinOps toolkit.
#
# Usada somente no modelo Container Apps. No App Service o deploy e por zip e este arquivo nao e
# necessario. O instalador constroi esta imagem NA NUVEM (az acr build): nao precisa de Docker na
# maquina de quem instala.
#
# Imagem base do Microsoft Container Registry, e nao do Docker Hub: o build na nuvem (ACR Tasks) sai de
# IPs compartilhados e o Docker Hub limita pulls anonimos por IP ("toomanyrequests"). O MCR nao limita.

FROM mcr.microsoft.com/devcontainers/python:3.11-bookworm AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    MPLCONFIGDIR=/tmp/matplotlib

WORKDIR /app

# As dependencias vem antes do codigo para aproveitar o cache de camada do Docker:
# mudar o codigo nao refaz a instalacao dos pacotes.
COPY api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY api/ ./api/
COPY static/ ./static/

# Arquivos de desenvolvimento nao tem funcao em producao.
RUN rm -f ./api/test_local.py ./api/test_import.py ./api/demo_data.py && rm -rf ./api/__pycache__

# Usuario sem privilegio: o processo nao precisa de root para servir HTTP.
RUN useradd --create-home --shell /bin/bash finops && chown -R finops:finops /app
USER finops

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=6s --start-period=25s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/health', timeout=5).status == 200 else 1)"

# Um unico processo uvicorn (o agendador de alertas roda dentro dele e nao pode duplicar).
# Escala horizontal, se precisar, vem das replicas do Container Apps, nao de workers no container.
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--app-dir", "api", "--timeout-keep-alive", "75"]
