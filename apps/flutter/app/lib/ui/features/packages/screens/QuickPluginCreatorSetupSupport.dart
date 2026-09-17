// ignore_for_file: file_names

import '../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../main/navigation/ToolPkgCatalogChangeBus.dart';

class QuickPluginCreatorSetupResult {
  const QuickPluginCreatorSetupResult({
    required this.success,
    required this.skillName,
    required this.packageResult,
    required this.error,
  });

  final bool success;
  final String skillName;
  final String packageResult;
  final String? error;
}

Future<QuickPluginCreatorSetupResult> runQuickPluginCreatorSetup(
  GeneratedCoreProxyClients clients,
) async {
  try {
    final skill = await clients.application
        .skillRepository()
        .ensureQuickPluginCreatorSkillVisible();
    final packageResult = await clients.application
        .packageManager()
        .enablePackage(packageName: 'operit_editor');
    ToolPkgCatalogChangeBus.notifyCatalogChanged();
    return QuickPluginCreatorSetupResult(
      success: true,
      skillName: skill.name,
      packageResult: packageResult,
      error: null,
    );
  } catch (error) {
    return QuickPluginCreatorSetupResult(
      success: false,
      skillName: '',
      packageResult: '',
      error: error.toString(),
    );
  }
}
