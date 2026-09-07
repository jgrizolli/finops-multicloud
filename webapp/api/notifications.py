"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Envio de e-mail para os alertas.

Tres caminhos, escolhidos automaticamente pelas variaveis de ambiente:
  1. Azure Communication Services  ACS_ENDPOINT + EMAIL_SENDER, com identidade gerenciada.
                                   Sem segredo. E o caminho recomendado no Azure.
  2. SMTP                          SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, EMAIL_SENDER.
                                   Para ambientes fora do Azure ou com relay corporativo.
  3. Nenhum                        os alertas aparecem so no painel e o envio e registrado no log.
"""

from __future__ import annotations

import logging
import os
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import sobre

log = logging.getLogger("finops.email")


def configurado() -> dict:
    acs = bool(os.getenv("ACS_ENDPOINT")) and bool(os.getenv("EMAIL_SENDER"))
    smtp = bool(os.getenv("SMTP_HOST")) and bool(os.getenv("EMAIL_SENDER"))
    return {"acs": acs, "smtp": smtp, "ativo": acs or smtp,
            "destinatariosPadrao": [d.strip() for d in os.getenv("ALERT_EMAIL_TO", "").split(",") if d.strip()],
            "remetente": os.getenv("EMAIL_SENDER", "")}


def _html_alerta(alerta: dict, url_app: str) -> str:
    cor = {"critico": "#E5484D", "atencao": "#FFB900", "informativo": "#0078D4"}.get(alerta.get("severidade"), "#0078D4")
    valor = alerta.get("valorFormatado") or ""
    return f"""<!doctype html><html><body style="font-family:Segoe UI,Arial,sans-serif;background:#F3F6FB;padding:24px">
<div style="max-width:640px;margin:auto;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #DCE5F0">
  <div style="background:{cor};color:#fff;padding:16px 22px">
    <div style="font-size:11px;letter-spacing:1px;text-transform:uppercase;opacity:.9">{sobre.NOME} · alerta {alerta.get('severidade','')}</div>
    <div style="font-size:19px;font-weight:600;margin-top:4px">{alerta.get('titulo','')}</div>
  </div>
  <div style="padding:20px 22px;color:#10203A;font-size:14px;line-height:1.55">
    <p style="margin:0 0 12px">{alerta.get('detalhe','')}</p>
    {f'<p style="margin:0 0 12px;font-size:22px;font-weight:700">{valor}</p>' if valor else ''}
    {f'<p style="margin:0 0 12px;padding:10px 14px;background:#F3F6FB;border-radius:8px"><b>O que fazer:</b> {alerta["acao"]}</p>' if alerta.get('acao') else ''}
    <p style="margin:0;font-size:12px;color:#52658A">Regra: {alerta.get('regraNome','')} · Escopo: {alerta.get('escopo','total')}</p>
    {f'<p style="margin:16px 0 0"><a href="{url_app}/#/alertas" style="background:#0078D4;color:#fff;text-decoration:none;padding:9px 16px;border-radius:8px;font-weight:600">Abrir no painel</a></p>' if url_app else ''}
  </div>
  <div style="padding:12px 22px;border-top:1px solid #DCE5F0;font-size:11px;color:#8496B4">{sobre.CREDITO_CURTO}</div>
</div></body></html>"""


def enviar(destinatarios: list[str], assunto: str, html: str) -> tuple[bool, str]:
    cfg = configurado()
    destinatarios = [d for d in destinatarios if d and "@" in d]
    if not destinatarios:
        return False, "sem destinatarios"

    if cfg["acs"]:
        try:
            from azure.communication.email import EmailClient
            from azure.identity import DefaultAzureCredential

            cliente = EmailClient(os.environ["ACS_ENDPOINT"], DefaultAzureCredential(exclude_interactive_browser_credential=True))
            mensagem = {"senderAddress": cfg["remetente"],
                        "recipients": {"to": [{"address": d} for d in destinatarios]},
                        "content": {"subject": assunto, "html": html}}
            poller = cliente.begin_send(mensagem)
            resultado = poller.result()
            return True, f"ACS {resultado.get('status', 'enviado')}"
        except Exception as exc:  # noqa: BLE001
            log.exception("Falha no envio via ACS")
            return False, f"ACS: {exc}"

    if cfg["smtp"]:
        try:
            msg = MIMEMultipart("alternative")
            msg["Subject"], msg["From"], msg["To"] = assunto, cfg["remetente"], ", ".join(destinatarios)
            msg.attach(MIMEText(html, "html", "utf-8"))
            porta = int(os.getenv("SMTP_PORT", "587"))
            with smtplib.SMTP(os.environ["SMTP_HOST"], porta, timeout=30) as s:
                if os.getenv("SMTP_STARTTLS", "true").lower() != "false":
                    s.starttls()
                if os.getenv("SMTP_USER"):
                    s.login(os.environ["SMTP_USER"], os.getenv("SMTP_PASSWORD", ""))
                s.sendmail(cfg["remetente"], destinatarios, msg.as_string())
            return True, "SMTP enviado"
        except Exception as exc:  # noqa: BLE001
            log.exception("Falha no envio via SMTP")
            return False, f"SMTP: {exc}"

    log.info("E-mail nao configurado. Alerta '%s' ficou so no painel. Destinatarios: %s", assunto, destinatarios)
    return False, "e-mail nao configurado"


def notificar_alerta(alerta: dict, destinatarios: list[str]) -> tuple[bool, str]:
    url_app = os.getenv("APP_URL", "")
    assunto = f"[{sobre.NOME}] {alerta.get('severidade', '').upper()}: {alerta.get('titulo', '')}"
    return enviar(destinatarios, assunto, _html_alerta(alerta, url_app))
