import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operit2/data/preferences/UserPreferencesManager.dart';
import 'package:operit2/ui/main/components/DrawerContent.dart';
import 'package:operit2/ui/main/components/DrawerConversationState.dart';
import 'package:operit2/ui/main/layout/PhoneLayout.dart';
import 'package:operit2/ui/theme/OperitTheme.dart';

/// Verifies drawer transitions preserve the mounted conversation list and input.
void main() {
  for (final enableNavigationAnimation in <bool>[true, false]) {
    testWidgets(
      'preserves drawer state across transitions (effects: $enableNavigationAnimation)',
      (tester) async {
        final drawerOpen = ValueNotifier<bool>(false);
        final conversations = ValueNotifier<DrawerConversationState>(
          const DrawerConversationState(loading: false),
        );
        addTearDown(drawerOpen.dispose);
        addTearDown(conversations.dispose);

        await tester.pumpWidget(
          OperitTheme(
            initialThemePreferenceSnapshot:
                UserPreferencesManager.defaultThemePreferenceSnapshot,
            initialThemeIsReady: false,
            unconfiguredChildEnabled: true,
            hostInteractionHostsEnabled: false,
            child: Scaffold(
              body: PhoneLayout(
                content: const SizedBox.expand(),
                navigationEntries: const [],
                pluginSidebarEntries: const [],
                selectedRouteId: 'ai_chat',
                drawerConversationState: conversations,
                drawerWidth: 300,
                drawerOpenState: drawerOpen,
                enableNavigationAnimation: enableNavigationAnimation,
                onOpenDrawer: () => drawerOpen.value = true,
                onCloseDrawer: () => drawerOpen.value = false,
                onNavigationEntrySelected: (_) {},
                onConversationActivated: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final drawerState = tester.state(find.byType(DrawerContent));

        drawerOpen.value = true;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(DrawerContent)), same(drawerState));

        await tester.tap(find.byTooltip('搜索对话'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'retained query');
        await tester.pumpAndSettle();

        for (var cycle = 0; cycle < 3; cycle++) {
          drawerOpen.value = false;
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(DrawerContent)), same(drawerState));

          drawerOpen.value = true;
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(DrawerContent)), same(drawerState));
          expect(find.text('retained query'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
