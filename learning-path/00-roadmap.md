# Módulo 00 — Roadmap: como aprender e subir um ecossistema de streaming na AWS

> **Objetivo do material:** levar você do zero a colocar uma plataforma de streaming de vídeo (VOD + live) em produção na AWS, com infraestrutura como código, observabilidade, CI/CD e custo controlado.

---

## 1. Como este material foi pensado

Cada módulo é um **arquivo independente** projetado para 3 modos de uso:

1. **NotebookLM** — você sobe os arquivos como fontes e conversa com eles. Cada módulo é autocontido (define termos, dá analogias e exemplos), então o NotebookLM consegue responder perguntas profundas sem precisar dos outros módulos como contexto.
2. **Estudo dirigido** — leia, faça os laboratórios, marque o checklist. Tudo está em ordem; pular módulos quebra a continuidade dos labs.
3. **Referência prática** — depois de aprender, cada módulo serve como cola de bolso para o dia-a-dia.

### Estrutura padrão de cada módulo

```
1. Conceitos     — definições, analogias, modelos mentais
2. Por que importa no streaming   — o "para quê" no nosso projeto
3. Laboratório prático            — passo a passo (Console + CLI/Terraform)
4. Armadilhas e custos            — o que vai te queimar dinheiro/tempo
5. Checklist de domínio           — "sei o suficiente quando..."
6. Recursos                       — docs oficiais, vídeos, livros
```

---

## 2. Mapa dos módulos (ordem recomendada)

| # | Módulo | Pré-requisito | Tempo estimado |
|---|--------|---------------|----------------|
| 01 | Fundamentos AWS | nenhum | 4–6h |
| 02 | Networking & VPC | 01 | 6–10h |
| 03 | IAM & Segurança | 01 | 6–8h |
| 04 | Storage & CDN (S3 + CloudFront) | 01, 03 | 6–8h |
| 05 | Bancos de dados (RDS, DynamoDB) | 02, 03 | 8–12h |
| 06 | Cache (Redis / ElastiCache) | 02, 05 | 4–6h |
| 07 | Mensageria (SQS, SNS, EventBridge, MQ) | 03 | 6–8h |
| 08 | Compute (EC2, ECS/Fargate, Lambda) | 02, 03 | 10–14h |
| 09 | Hosting de aplicação NestJS (SSR) | 04, 08 | 6–10h |
| 10 | Pipeline de transcodificação em EC2 GPU | 04, 07, 08 | 12–16h |
| 11 | Terraform | 01–08 | 8–12h |
| 12 | Observabilidade | 08 | 6–8h |
| 13 | Escalabilidade | 08, 12 | 6–8h |
| 14 | FinOps & gestão de custos | qualquer | 4–6h |
| 15 | CI/CD & Pipelines | 08, 11 | 8–12h |
| 16 | Projeto final — streaming platform | TODOS | 30–60h |
| 17 | Redução de custos avançada | 14 + todos | 4–6h |
| 18 | Alternativas e comparações | TODOS | 4–6h |

**Total estimado:** 4 a 8 semanas em ritmo de 2h/dia, ou 2–3 meses confortáveis com 1h/dia + fins de semana.

---

## 3. Pré-requisitos antes de começar o módulo 01

### Conhecimento

- Linux básico (terminal, navegação, ssh).
- Git em nível básico (clone, commit, push, branch).
- Uma linguagem de programação (Node.js, Python ou Go são as mais usadas nos exemplos).
- HTTP / REST em nível conceitual (GET/POST, status codes, JSON).

> Se algum item acima é novo, não pule — gaste 1–2 dias com tutoriais antes do módulo 01.

### Ambiente local (instale antes do módulo 01)

```bash
# macOS (homebrew). Em Linux, use o gerenciador de pacotes equivalente.
brew install awscli terraform jq git
brew install --cask docker
```

Ferramentas extras úteis:

- **`session-manager-plugin`** — para acessar EC2 sem SSH (`brew install --cask session-manager-plugin`).
- **`aws-vault`** — gerenciar credenciais AWS com segurança (`brew install --cask aws-vault`).
- **VS Code** com extensão "HashiCorp Terraform" e "AWS Toolkit".

### Conta AWS

- Crie a conta com **e-mail dedicado** (não use o pessoal principal).
- Use cartão de crédito virtual com limite, se possível.
- **Ative MFA na conta root no primeiro dia** (módulo 01 mostra como).
- Configure **billing alert de US$ 5, US$ 10 e US$ 50** antes de criar qualquer recurso.

---

## 4. Mentalidade para aprender cloud

### A regra dos 3 modos

Para cada serviço que você aprender, pratique nos 3 modos:

1. **Console (clica-clica)** — para entender visualmente o que existe.
2. **CLI (`aws` + scripts)** — para entender o que cada clique fez por baixo.
3. **IaC (Terraform)** — como você de fato vai operar em produção.

Pular do console direto para Terraform sem passar pela CLI faz você não entender erros quando aparecem.

### A pirâmide do "por que"

Quando aparece um conceito novo (ex: "VPC endpoint"), pare e responda 3 perguntas:

1. **O quê?** — definição em uma frase.
2. **Por quê existe?** — qual problema resolve, o que era ruim antes.
3. **Quando NÃO usar?** — todo serviço tem trade-off; saber quando evitar.

A maioria dos cursos só ensina o "como". Você quer o "por quê" também — é o que separa quem segue tutorial de quem desenha arquitetura.

### Custos: paranoia saudável

A AWS é uma gigante que cobra centavos por operação — e centavos viram milhares se você esquecer um cluster ligado. Regras de ouro:

- **Toda noite, antes de dormir, rode `aws ce get-cost-and-usage`** ou olhe o Cost Explorer. Bug pequeno, prejuízo grande.
- **Tag tudo com `Project=streaming-learning`** desde o módulo 01. Dá para filtrar custo por projeto.
- **Crie e destrua** ambientes de lab. Não deixe RDS, NAT Gateway ou Elasticache rodando "por garantia".
- **NAT Gateway** custa ~US$ 35/mês mesmo parado. Em laboratório, prefira VPC sem NAT (instâncias públicas controladas por SG) ou NAT instances pequenas.

---

## 5. Como usar com o NotebookLM

1. Crie um notebook por módulo (ou um único notebook com todos os módulos como fontes).
2. Sugestões de prompts para conversar com o material:
   - "Explique a diferença entre security group e NACL como se eu tivesse 12 anos."
   - "Liste todos os custos potencialmente surpresa mencionados no material."
   - "Quais módulos preciso ter dominado para começar o 10 (streaming)?"
   - "Crie 10 perguntas de prova sobre IAM com gabarito comentado."
   - "Quais são as 3 armadilhas mais caras citadas?"
3. Use o NotebookLM como **tutor**, não como fonte primária. Sempre confirme com a doc oficial da AWS antes de aplicar em produção.

---

## 6. Estratégia prática por sprint

Sugestão de 8 sprints (1 sprint = 1 semana de 10–15h de estudo):

| Sprint | Módulos | Entregável |
|--------|---------|------------|
| 1 | 00, 01, 02 | Conta segura + 1 VPC funcional |
| 2 | 03, 04 | Bucket S3 servindo via CloudFront com HTTPS |
| 3 | 05, 06 | RDS + Redis subindo via console |
| 4 | 07, 08 | Lambda + SQS + ECS Fargate hello-world |
| 5 | 09, 10 | Frontend deployado + 1 vídeo VOD encodado |
| 6 | 11 | Toda a infra dos sprints anteriores em Terraform |
| 7 | 12, 13, 14 | Dashboard + auto scaling + budget configurados |
| 8 | 15, 16 | Pipeline de upload→encode→entrega ponta a ponta |

Cada sprint termina **destruindo o ambiente** e subindo via Terraform na sprint seguinte. Isso força repetição.

---

## 7. Convenções deste material

- Comandos com `$` no início são executados no seu terminal local.
- Comandos com `>` no início são prompts dentro do AWS CloudShell ou de uma sessão SSM.
- **`<placeholder>`** sempre substitua pelo seu valor real.
- Blocos marcados com **⚠️ Cuidado** custam dinheiro ou são irreversíveis.
- Blocos marcados com **💡 Dica** são atalhos que economizam tempo.
- Blocos marcados com **🧪 Lab** são exercícios obrigatórios.

---

## 8. O que você terá ao final

Uma plataforma de streaming com:

- Upload de vídeos por usuários autenticados (Cognito + S3 presigned URL).
- Pipeline de transcodificação em **EC2 com GPU** (instâncias `g4dn`/`g5`) rodando FFmpeg via worker que consome fila SQS, gerando HLS/DASH em múltiplos bitrates.
- Catálogo persistido em DynamoDB, metadados em RDS, cache em Redis.
- Aplicação **NestJS com SSR** servida em ECS Fargate (ou EC2) atrás de ALB + CloudFront (para edge cache de assets estáticos e HTML cacheável).
- Sinalização de eventos via SNS/SQS/EventBridge para emails, analytics e notificações.
- Backend (APIs internas) em Lambda + ECS Fargate atrás de API Gateway.
- Tudo provisionado por **Terraform** com pipeline de CI/CD em **GitHub Actions**.
- Dashboards no CloudWatch e tracing distribuído com X-Ray.
- Custo mensal documentado, otimizado e alertado.

---

## 9. Checklist de pronto-para-começar

- [ ] Conta AWS criada com e-mail dedicado
- [ ] MFA ativado na conta root
- [ ] Billing alerts criados (5/10/50 USD)
- [ ] AWS CLI, Terraform, Docker, Git instalados
- [ ] Editor (VS Code recomendado) com extensões instaladas
- [ ] Diretório do projeto criado e commitado em um repositório Git
- [ ] Cartão de crédito com limite controlado vinculado à conta

Se tudo está marcado: bora pro **módulo 01**.
