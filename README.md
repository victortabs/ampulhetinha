# ⏳ Ampulhetinha

Recriação nativa (Swift/AppKit + SwiftUI) do Gestimer 1: um timer que mora na barra de menus.

## Como usar

- **Clique e arraste a ampulheta para baixo.** Quanto mais longe, mais tempo (~300 pt ≈ 50 min; o pé da tela vale 12 h por padrão).
  - Segure **⌥** durante o arrasto para andar de minuto em minuto.
  - Volte até perto do ícone e solte para **cancelar**.
- Ao soltar, digite o título e tecle **↩**. **↑/↓** ajustam o tempo (±1 min, com ⇧ ±5 min). **esc** cancela. Clicar fora cria o timer com o que já foi digitado.
- **Clique** na ampulheta para ver a lista: adiar (+5), concluir, excluir, renomear (duplo clique no título), botão direito para mais opções. Timers terminados ficam em *Recentes*, com o botão **Repetir**.
- A notificação traz *Adiar 5 min / 15 min / 1 hora* e *Concluir*.

## App Lembretes

- Cada timer vira um lembrete (na lista padrão ou na lista escolhida nos Ajustes).
- Se você concluir, excluir, renomear ou mudar o horário do lembrete no app Lembretes (inclusive no iPhone), a Ampulhetinha acompanha.
- Os lembretes **com horário** dos próximos 7 dias aparecem na lista e na contagem da barra de menus.
- Opção *Alarme também no app Lembretes* para receber o aviso no iPhone/iPad.

## Instalar em um Mac

Precisa só das Command Line Tools (não precisa do Xcode). Se ainda não tiver:

```bash
xcode-select --install
```

Depois:

```bash
git clone https://github.com/victortabs/ampulhetinha.git
cd ampulhetinha
./Scripts/build.sh install
```

Para atualizar mais tarde: `git pull && ./Scripts/build.sh install`.

Isso compila, monta `build/Ampulhetinha.app`, instala em `/Applications` e abre o app.

> A assinatura é ad-hoc (não há certificado de desenvolvedor), então a cada recompilação o macOS pode pedir de novo a permissão dos Lembretes.

## Estrutura

| Arquivo | O quê |
|---|---|
| `StatusItemController.swift` | ícone na barra de menus, captura do gesto, popover |
| `DragOverlay.swift` | linha, bolinha e bolha com relógio desenhadas durante o arrasto |
| `Panels.swift` | campo de título ao soltar e janela de alerta |
| `TimerStore.swift` | estado, persistência (`~/Library/Application Support/Ampulhetinha`), expiração, reconciliação |
| `RemindersSync.swift` | EventKit (app Lembretes) |
| `Notifications.swift` | notificações com ações |
| `Model.swift` | modelo, curva distância→tempo, formatação em português |
| `Views.swift` | lista e Ajustes (SwiftUI) |
