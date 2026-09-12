# Fluxo de trabalho: múltiplas máquinas, GitHub e VPS de produção

Este repositório é editado por sessões de Claude Code rodando em **mais de uma
máquina ao mesmo tempo**, e é implantado numa VPS compartilhada
(`145.223.26.168`) via `bin/deploy_vps.sh`. As duas regras abaixo existem
porque já foram violadas na prática e causaram um incidente real de
produção — leia antes de mesclar ou implantar qualquer coisa.

## Incidente que gerou esta regra (2026-09-10/12)

Uma sessão numa outra máquina publicou várias features direto da branch
compartilhada `feat/multi-feature-sync-20260901` pra produção, usando
`DEPLOY_BRANCH=feat/multi-feature-sync-20260901 bin/deploy_vps.sh` (ou
equivalente) em vez de mesclar essa branch em `main` e implantar a partir
dela. Isso funcionou tecnicamente (o script só verifica que o HEAD local
bate com `origin/<a branch usada>`, não especificamente `main`), mas criou
um problema sério: **`main` no GitHub e a produção divergiram** — a
produção ficou 27 commits "à frente" do GitHub, mas sem um fix crítico de
segurança que só existia em `main` (timeout do OAuth2 client do Google que
travava threads do Puma indefinidamente e derrubava a API inteira — ver
`GoogleConcern#google_client`). Esse fix ficou fora do ar em produção por
dois dias sem que ninguém percebesse, porque "o deploy funcionou" e
ninguém comparou o que estava rodando com o que o GitHub mostrava.

## Regra 1 — nunca implante a partir de uma branch que não seja `main`

`bin/deploy_vps.sh` tem `DEPLOY_BRANCH` como variável de ambiente
justamente pra permitir isso, mas **não use essa opção para "publicar
agora, mesclar depois"**. Se você faz isso, cria exatamente a divergência
do incidente acima. As únicas duas formas corretas de implantar são:

```bash
# 1) mesclar a branch de trabalho compartilhada em main (ver Regra 2)
git checkout main && git pull && git merge --no-ff origin/feat/<branch-compartilhada>
# ... resolver conflitos, verificar, commitar, dar push ...
git push origin main

# 2) só ENTÃO implantar, sempre a partir de main
bin/deploy_vps.sh both "descrição-curta-do-que-mudou"
```

Se em algum momento for genuinamente necessário um hotfix implantado direto
de uma branch (emergência real), **mescle essa branch em `main` e dê push
imediatamente depois**, antes de encerrar a sessão — nunca deixe o hotfix
"pendurado" só na branch.

## Regra 2 — antes de mexer em qualquer coisa, compare os três estados

Como o trabalho acontece em várias máquinas, no início de qualquer sessão
(e antes de qualquer merge/deploy) verifique se os três estados abaixo
batem — eles podem ter divergido sem que ninguém tenha avisado:

1. **O que está no GitHub** (`git fetch --all && git log origin/main -5` e
   `git log origin/feat/<branch-compartilhada> -5` — veja se a branch
   compartilhada tem commits que `main` ainda não tem).
2. **O que está localmente** (`git status`, `git log -5`).
3. **O que está de fato rodando na VPS** — a tag da imagem Docker já
   carrega o timestamp + SHA curto do commit + uma nota:
   ```bash
   ssh -i ~/.ssh/id_ed25519_vps_crm root@145.223.26.168 \
     "docker service inspect evocrm_evocrm_crm --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'"
   ```
   Compare o SHA curto da tag com `git log --oneline` / `git merge-base
   --is-ancestor <sha> origin/main`. Em caso de dúvida sobre se um fix
   específico está mesmo em produção, a fonte da verdade é inspecionar o
   código rodando dentro do próprio container, não inferir pelo git:
   ```bash
   ssh -i ~/.ssh/id_ed25519_vps_crm root@145.223.26.168 \
     "docker exec \$(docker ps -q -f name=evocrm_evocrm_crm.1) grep -A5 'def algum_metodo' /app/caminho/do/arquivo.rb"
   ```

Se encontrar divergência (produção com commits que `main` não tem, ou
`main` com commits que a branch compartilhada não tem), pare e resolva
isso primeiro — não continue empilhando trabalho novo em cima de um
histórico que já está torto.

## Checklist de merge (aplicar sempre, mesmo sob pressão de um fix urgente)

1. `git merge --no-commit --no-ff origin/<branch>` (nunca `--ff`, nunca
   pular a etapa de revisão mesmo que pareça "só aditivo").
2. Ler CADA conflito por completo — entender a intenção dos dois lados, não
   só o diff textual. Preferir o lado mais completo/testado; nunca
   descartar funcionalidade de um lado sem motivo técnico claro. Se as duas
   pontas parecerem redesenhos incompatíveis da mesma área (não um conflito
   textual trivial), investigue qual é mais recente/completa antes de
   decidir — `git merge-base --is-ancestor <commit> <branch>` e `git log
   --oneline <branch> -- <arquivo>` ajudam a provar qual lado é "mais
   velho" e já foi substituído.
3. Rodar `rails db:migrate` regenera comentários de schema (`annotate`) em
   **todos** os modelos anotados do repo, não só os tocados pela migration
   atual — às vezes apagando comentários explicativos escritos à mão. Depois
   de migrar, cheque `git diff` em todo modelo que aparecer como modificado
   e não fizer parte do que você está mesclando: se for só annotate
   cosmético em arquivo não relacionado, `git checkout --` nele; se um
   comentário manual foi apagado, restaure-o manualmente.
4. Verificação mínima antes de commitar o merge:
   - `rails runner "Rails.application.eager_load!; puts 'OK'"` (pega
     referência quebrada/import que `rails runner` sozinho, sem eager
     load, não pegaria em dev)
   - `rails routes` (carrega sem erro)
   - `rails db:migrate`
   - `rubocop` nos arquivos novos/tocados (ofensas de estilo/complexidade
     pré-existentes do outro lado não bloqueiam; erro de sintaxe ou
     referência quebrada, sim)
5. Commit com mensagem detalhada explicando CADA conflito resolvido e por
   quê. `git push origin main`. Só depois, `bin/deploy_vps.sh both <nota>`.
6. Depois do deploy: `curl` checando 200 em
   `https://api-crmcerto.anunciocertobr.com.br/api/v1/global_config`, e se
   o merge envolveu um fix de segurança/estabilidade, confirmar
   diretamente no container rodando (ver Regra 2, item 3) que ele está
   mesmo lá — não confiar só no "deploy sem erro".

## Docker local (dev)

O container de dev (`evo-crm-community-evo-crm-1`, via docker-compose local)
não tem os dados reais de produção (`Integrations::Hook` etc.) — pra testar
integrações externas de verdade (Google, Meta, etc.) contra credenciais
reais, é preciso rodar via SSH no container de produção, com cuidado.
