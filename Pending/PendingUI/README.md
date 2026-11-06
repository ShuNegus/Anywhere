# Pending UI (merge of upstream 2.6, stage 1)

Our home screen and settings shell as of build 355 (`main` f3857906), parked here while
the upstream 2.6 merge lands the core. These files are NOT part of the Xcode project.
Stage 2 ports them onto upstream's new architecture (AppContainer / TunnelController /
operations instead of the old VPNViewModel and `.shared` stores) and wires them in as
the default UI, with upstream's pages behind Pro Mode.

- HomeView.swift, ServerListSection.swift, ConnectionGraphSection.swift, TurnStatusIcon.swift,
  ConnectionStatsView.swift: the home screen (mockup design, backup-route status).
- MainTabView.swift, SettingsView.swift, SettingsItem.swift: tab shell and settings.
- VPNViewModel.swift: the old view model; its TURN logic is ported to
  `Shared/ViewModels/TurnSessionModel.swift`.
