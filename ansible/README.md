# Ansible — deploy da plataforma VOD

Pré-requisitos: Terraform aplicado (Planos 1–2), Docker, Node 20, AWS CLI configurado.

Ordem típica de um deploy completo:

    ansible-galaxy collection install -r requirements.yml -p ./.galaxy
    ansible-playbook build-push.yml
    ansible-playbook deploy.yml
    ansible-playbook configure-broker.yml --ask-vault-pass
    ansible-playbook web-client.yml
    ansible-playbook smoke.yml

Segredos do broker ficam em `vault.yml` (Ansible Vault). Endpoints vêm dos
outputs do Terraform em `../aws`.
