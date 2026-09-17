# dashboards-src

Snapshot/histórico de dashboards legados que vivem como conteúdo HTML dentro
do `MenuConfig` (escopo `editor-menus`) em produção, renderizados via a aba
Editor do CRM (`/editor/content/:id`) dentro de um iframe sandboxed — não são
servidos a partir destes arquivos.

## painel_trafego.html

"Painel Tráfego" (Gerenciador de Anúncios da Meta) — id do node no Editor:
`mtlsqe9g-44xt89`. Este arquivo é um snapshot do HTML/JS real que está em
produção no momento deste commit, guardado aqui só para ter histórico de
versão (antes disso, mudanças nele eram feitas direto no banco, sem nenhum
rastro em git).

Está em processo de migração pra uma página nativa em React dentro do CRM
(reaproveitando `Meta::AdsManagerService` no backend, que já é usado por
este arquivo via o endpoint `/api/v1/reports/meta_ads_manager`). Depois que
a migração terminar, este arquivo deixa de ser tocado e pode ser removido
do `MenuConfig`.

**Para atualizar este snapshot manualmente enquanto a migração não termina**
(sem `rails console` na mão): buscar o conteúdo atual do `MenuConfig` scope
`editor-menus`, achar o node de id `mtlsqe9g-44xt89` na árvore de `items`, e
copiar o campo `html` pra este arquivo.
