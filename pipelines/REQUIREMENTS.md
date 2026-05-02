# Requisitos Consolidados do Pipeline (CI/CD, Segurança e Qualidade)

Este documento consolida todos os requisitos de implementação (checklist de tarefas) organizados por Épico e Tarefa correspondente, com foco exclusivo em GitHub Actions.

## Pipeline Base (CI/CD)

### 1.1 - Configurar pipeline inicial
- [ ] Criar pipeline no GitHub Actions
- [ ] Configurar triggers: Pull Request e Merge na main
- [ ] Adicionar etapa de build
- [ ] Adicionar execução de testes unitários
- [ ] Configurar cache de dependências

### 1.2 - Padronização de execução
- [ ] Definir padrão de pipeline YAML
- [ ] Criar template reutilizável
- [ ] Documentar fluxo CI/CD

## Code Quality & Code Smells

### 2.1 - Integração com análise de qualidade
- [ ] Integrar SonarQube ou SonarCloud
- [ ] Configurar análise no PR
- [ ] Configurar métricas: Code smells, Complexidade, Coverage

### 2.2 - Quality Gate
- [ ] Definir regras: Coverage mínimo (ex: 80%), Code smells críticos = 0
- [ ] Configurar bloqueio de PR
- [ ] Testar cenário de falha

## Segurança (SAST, SCA, Secrets)

### 3.1 - SAST análise estática
- [ ] Integrar CodeQL ou Semgrep
- [ ] Rodar análise no PR
- [ ] Configurar severidade (High bloqueia PR)

### 3.2 - SCA dependências
- [ ] Integrar Snyk ou Dependabot
- [ ] Configurar alertas automáticos
- [ ] Habilitar PR automático de update

### 3.3 - Secrets scanning
- [ ] Integrar Gitleaks
- [ ] Bloquear commit com secrets
- [ ] Criar política de rotação de credenciais

### 3.4 - Container e IaC
- [ ] Integrar Trivy
- [ ] Scan de Dockerfile
- [ ] Scan de Terraform/Kubernetes

## Duplicação de Código

### 4.1 - Detecção de duplicação
- [ ] Habilitar duplicação no SonarQube
- [ ] Definir threshold (ex: 3%)
- [ ] Exibir no PR

### 4.2 - Ação sobre duplicação
- [ ] Bloquear PR acima do limite
- [ ] Criar guideline de refatoração
- [ ] Criar exemplos de boas práticas

## Guardrails & Quality Gates

### 5.1 - Definir regras globais
- [ ] Definir critérios de bloqueio: Vulnerabilidade crítica, Coverage baixo, Duplicação alta
- [ ] Criar policy document

### 5.2 - Enforcement automático
- [ ] Integrar regras no pipeline
- [ ] Configurar status checks obrigatórios
- [ ] Validar bloqueio de merge

### 5.3 - Guardrails para IA
- [ ] Definir regras para código gerado por IA
- [ ] Criar checklist automático no PR
- [ ] Integrar análise adicional em arquivos suspeitos

## Auto-remediação (Correção automática)

### 6.1 - Auto-fix de lint
- [ ] Configurar ESLint/Pylint com autofix
- [ ] Rodar correção automática no pipeline
- [ ] Commit automático (opcional)

### 6.2 - Correção de vulnerabilidades
- [ ] Habilitar autofix do Semgrep
- [ ] Testar geração automática de patch
- [ ] Criar PR automático de correção

### 6.3 - Correção de dependências
- [ ] Configurar PR automático via Dependabot/Snyk
- [ ] Testar atualização segura
- [ ] Validar compatibilidade via testes

### 6.4 - Assistente de refatoração
- [ ] Integrar ferramenta de sugestão (ex: CodeRabbit)
- [ ] Gerar sugestões de melhoria no PR
- [ ] Validar melhorias com equipe

## Observabilidade & Dashboard

### 7.1 - Centralizar métricas
- [ ] Coletar dados do pipeline
- [ ] Consolidar resultados (SARIF ou similar)
- [ ] Criar API interna de métricas

### 7.2 - Dashboard de qualidade
- [ ] Exibir: Bugs, Vulnerabilidades, Duplicação, Coverage
- [ ] Criar visão por repositório

### 7.3 - Tracking de evolução
- [ ] Medir dívida técnica
- [ ] Medir tempo de correção (MTTR)
- [ ] Criar alertas de regressão

## Developer Experience

### 8.1 - Shift-left antes do PR
- [ ] Configurar pre-commit hooks
- [ ] Rodar lint local
- [ ] Rodar scan de segurança local

### 8.2 - Feedback rápido
- [ ] Reduzir tempo de pipeline
- [ ] Paralelizar execuções
- [ ] Cache de dependências

### 8.3 - Documentação
- [ ] Criar guia de uso da pipeline
- [ ] Criar guia de correção de erros comuns
- [ ] Criar onboarding para devs

