// ignore_for_file: file_names

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:operit2/core/browser/BrowserSessions.dart';
import 'package:operit2/core/bridge/ProxyCoreRuntimeBridge.dart';
import 'package:operit2/core/host/browser/RuntimeBrowserSessionRegistry.dart';
import 'package:operit2/core/proxy/generated/CoreProxyClients.g.dart';
import 'package:operit2/core/proxy/generated/CoreProxyModels.g.dart'
    as core_proxy;
import 'package:operit2/core/web_visit/WebVisitModels.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../theme/OperitGlassSurface.dart';
import '../../viewmodel/WorkspaceFileModels.dart';
import 'WorkspaceOverviewModels.dart';
import 'WorkspaceTabContent.dart';
import 'WorkspaceTabModels.dart';
import 'WorkspaceTabStrip.dart';
import 'browser/WorkspaceBrowserViewStore.dart';
import 'browser/automation/WorkspaceWebVisitSessionRegistry.dart';
import 'terminal/WorkspaceTerminalSessions.dart';

class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({
    super.key,
    required this.currentChatId,
    required this.hasBoundWorkspace,
    required this.workspacePath,
    required this.onListWorkspaceFiles,
    required this.onListWorkspaceBindingDirectories,
    required this.onReadWorkspaceTextFile,
    required this.onReadWorkspaceFileBytes,
    required this.onWriteWorkspaceFileBytes,
    required this.onOpenWorkspaceFile,
    required this.onCreateWorkspace,
    required this.onBindWorkspace,
  });

  final String? currentChatId;
  final bool hasBoundWorkspace;
  final String? workspacePath;
  final Future<List<WorkspaceFileEntry>> Function(String path)
  onListWorkspaceFiles;
  final Future<List<WorkspaceFileEntry>> Function(String path)
  onListWorkspaceBindingDirectories;
  final Future<String> Function(String path) onReadWorkspaceTextFile;
  final Future<Uint8List> Function(String path) onReadWorkspaceFileBytes;
  final Future<void> Function(String path, Uint8List bytes)
  onWriteWorkspaceFileBytes;
  final Future<void> Function(String path) onOpenWorkspaceFile;
  final Future<void> Function(String name) onCreateWorkspace;
  final Future<void> Function(String workspace) onBindWorkspace;

  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  static final GeneratedCoreProxyClients _coreClients =
      GeneratedCoreProxyClients(ProxyCoreRuntimeBridge());
  final BrowserSessions _browserSessions = BrowserSessions();
  final RuntimeBrowserSessionRegistry _browserSessionRegistry =
      RuntimeBrowserSessionRegistry.instance;
  final WorkspaceBrowserViewStore _browserViewStore =
      WorkspaceBrowserViewStore.instance;
  final WorkspaceWebVisitSessionRegistry _webVisitSessionRegistry =
      WorkspaceWebVisitSessionRegistry.instance;
  final WorkspaceTerminalSessions _terminalSessions =
      const WorkspaceTerminalSessions();
  final Map<String, Completer<WebVisitResponse>> _webVisitCompleters =
      <String, Completer<WebVisitResponse>>{};
  final List<WorkspaceTab> _tabs = <WorkspaceTab>[
    const WorkspaceTab(
      kind: WorkspaceTabKind.home,
      title: '',
      icon: Icons.home_outlined,
      closable: false,
    ),
  ];
  int _selectedIndex = 0;
  int _filesListingRevision = 0;
  int _workspaceTabIdentitySequence = 0;
  List<WorkspaceTerminalSessionInfo> _terminalSessionEntries =
      const <WorkspaceTerminalSessionInfo>[];
  final ValueNotifier<int> _terminalSessionCount = ValueNotifier<int>(0);
  final ValueNotifier<int> _browserSessionCount = ValueNotifier<int>(0);
  List<core_proxy.ChatHistoryListItem> _workspaceOverviewHistories =
      const <core_proxy.ChatHistoryListItem>[];
  List<WorkspaceFileEntry> _workspaceOverviewMountedFolders =
      const <WorkspaceFileEntry>[];
  Map<String, String> _workspaceOverviewCharacterAvatarsByName =
      const <String, String>{};
  bool _workspaceOverviewMountedFoldersLoading = false;
  String? _workspaceOverviewMountedFoldersError;
  int _workspaceOverviewMountedFoldersLoadGeneration = 0;
  StreamSubscription<List<WorkspaceTerminalSessionInfo>>?
  _terminalSessionSubscription;
  StreamSubscription<List<core_proxy.ChatHistoryListItem>>?
  _workspaceOverviewHistorySubscription;
  StreamSubscription<List<String>>? _workspaceOverviewCharacterIdsSubscription;
  final Map<String, StreamSubscription<core_proxy.CharacterCard>>
  _workspaceOverviewCharacterSubscriptions =
      <String, StreamSubscription<core_proxy.CharacterCard>>{};
  final Map<String, String> _workspaceOverviewCharacterNamesById =
      <String, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_browserViewStore.ensureLoaded());
    _browserSessionRegistry.addListener(_handleBrowserSessionRegistryChanged);
    _handleBrowserSessionRegistryChanged();
    _registerWebVisitControls();
    _watchWorkspaceOverviewHistories();
    _watchWorkspaceOverviewCharacterCards();
    unawaited(_loadWorkspaceOverviewCharacters());
    unawaited(_refreshWorkspaceOverviewMountedFolders());
    unawaited(_refreshTerminalSessionEntries());
    _terminalSessionSubscription = _terminalSessions.watchSessions().listen(
      (sessions) {
        if (!mounted) {
          return;
        }
        _updateTerminalSessionEntries(sessions);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Failed to watch terminal sessions: $error\n$stackTrace');
      },
    );
  }

  @override
  void didUpdateWidget(covariant WorkspacePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _registerWebVisitControls();
    final workspaceBindingChanged =
        oldWidget.currentChatId != widget.currentChatId ||
        oldWidget.hasBoundWorkspace != widget.hasBoundWorkspace ||
        oldWidget.workspacePath != widget.workspacePath;
    if (workspaceBindingChanged) {
      unawaited(_refreshWorkspaceOverviewMountedFolders());
    }
    if (!oldWidget.hasBoundWorkspace && widget.hasBoundWorkspace) {
      _replacePickerTabWithFilesTab();
    }
  }

  @override
  void dispose() {
    _webVisitSessionRegistry.clearControls();
    _browserSessionRegistry.removeListener(
      _handleBrowserSessionRegistryChanged,
    );
    unawaited(_workspaceOverviewHistorySubscription?.cancel());
    unawaited(_workspaceOverviewCharacterIdsSubscription?.cancel());
    for (final subscription
        in _workspaceOverviewCharacterSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final entry in _webVisitCompleters.entries) {
      final completer = entry.value;
      if (!completer.isCompleted) {
        completer.complete(
          WebVisitResponse(
            requestId: entry.key,
            success: false,
            error: 'visit_web workspace closed',
          ),
        );
      }
    }
    _webVisitCompleters.clear();
    unawaited(_terminalSessionSubscription?.cancel());
    _terminalSessionCount.dispose();
    _browserSessionCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OperitGlassSurface(
      color: theme.colorScheme.surface,
      layer: OperitGlassSurfaceLayer.panel,
      transparentAlpha: 0.035,
      borderRadius: BorderRadius.zero,
      material: true,
      clip: false,
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Column(
            children: <Widget>[
              WorkspaceTabStrip(
                tabs: _tabs,
                selectedIndex: _selectedIndex,
                onSelected: _selectTab,
                onClosed: _closeTab,
              ),
              Expanded(
                child: IndexedStack(
                  index: _selectedIndex,
                  children: <Widget>[
                    for (final tab in _tabs)
                      KeyedSubtree(
                        key: ValueKey<String>(_tabIdentity(tab)),
                        child: _buildTabContent(tab),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _registerWebVisitControls() {
    _webVisitSessionRegistry.setControls(openWebVisitTab: _openWebVisitTab);
  }

  /// Watches chat histories used by the workspace overview.
  void _watchWorkspaceOverviewHistories() {
    _workspaceOverviewHistorySubscription = _coreClients.chatRuntimeHolderMain
        .chatHistoryListItemsFlow()
        .listen(
          (histories) {
            if (!mounted) {
              return;
            }
            setState(() {
              _workspaceOverviewHistories =
                  List<core_proxy.ChatHistoryListItem>.unmodifiable(histories);
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              'Failed to watch workspace overview histories: $error\n$stackTrace',
            );
          },
        );
  }

  /// Watches character cards used by the workspace overview.
  void _watchWorkspaceOverviewCharacterCards() {
    _workspaceOverviewCharacterIdsSubscription = _coreClients
        .preferencesCharacterCardManager
        .characterCardListFlow()
        .listen(
          (cardIds) {
            unawaited(_syncWorkspaceOverviewCharacterSubscriptions(cardIds));
          },
          onError: (Object error, StackTrace stackTrace) {
            _reportWorkspaceOverviewCharacterError(error, stackTrace);
          },
        );
  }

  /// Loads current character-card metadata for the workspace overview.
  Future<void> _loadWorkspaceOverviewCharacters() async {
    try {
      final characterCardCoreProxy =
          _coreClients.preferencesCharacterCardManager;
      final cards = await characterCardCoreProxy.getAllCharacterCards();
      if (!mounted) {
        return;
      }
      await _applyWorkspaceOverviewCharacterSubscriptions(
        cards
            .map((card) => card.id.trim())
            .where((id) => id.isNotEmpty)
            .toSet(),
      );
      if (!mounted) {
        return;
      }
      _replaceWorkspaceOverviewCharacters(cards);
    } catch (error, stackTrace) {
      _reportWorkspaceOverviewCharacterError(error, stackTrace);
    }
  }

  /// Synchronizes character-card subscriptions for workspace overview metadata.
  Future<void> _syncWorkspaceOverviewCharacterSubscriptions(
    List<String> cardIds,
  ) async {
    try {
      final desiredCardIds = cardIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      await _applyWorkspaceOverviewCharacterSubscriptions(desiredCardIds);
      final characterCardCoreProxy =
          _coreClients.preferencesCharacterCardManager;
      final cards = await Future.wait<core_proxy.CharacterCard>(
        desiredCardIds.map(
          (id) => characterCardCoreProxy.getCharacterCard(id: id),
        ),
      );
      if (!mounted) {
        return;
      }
      _replaceWorkspaceOverviewCharacters(cards);
    } catch (error, stackTrace) {
      _reportWorkspaceOverviewCharacterError(error, stackTrace);
    }
  }

  /// Applies the active set of character-card stream subscriptions.
  Future<void> _applyWorkspaceOverviewCharacterSubscriptions(
    Set<String> desiredCardIds,
  ) async {
    final removedCardIds = _workspaceOverviewCharacterSubscriptions.keys
        .where((id) => !desiredCardIds.contains(id))
        .toList(growable: false);
    for (final cardId in removedCardIds) {
      await _workspaceOverviewCharacterSubscriptions.remove(cardId)!.cancel();
      final previousName = _workspaceOverviewCharacterNamesById.remove(cardId);
      if (previousName != null) {
        _removeWorkspaceOverviewCharacter(previousName);
      }
    }

    final characterCardCoreProxy = _coreClients.preferencesCharacterCardManager;
    for (final cardId in desiredCardIds) {
      if (_workspaceOverviewCharacterSubscriptions.containsKey(cardId)) {
        continue;
      }
      _workspaceOverviewCharacterSubscriptions[cardId] = characterCardCoreProxy
          .getCharacterCardFlow(id: cardId)
          .listen(
            _updateWorkspaceOverviewCharacter,
            onError: (Object error, StackTrace stackTrace) {
              _reportWorkspaceOverviewCharacterError(error, stackTrace);
            },
          );
    }
  }

  /// Replaces workspace overview character metadata.
  void _replaceWorkspaceOverviewCharacters(
    List<core_proxy.CharacterCard> cards,
  ) {
    final avatarUrisByName = <String, String>{};
    _workspaceOverviewCharacterNamesById.clear();
    for (final card in cards) {
      final cardId = card.id.trim();
      final cardName = card.name.trim();
      if (cardId.isEmpty || cardName.isEmpty) {
        continue;
      }
      _workspaceOverviewCharacterNamesById[cardId] = cardName;
      final avatarUri = card.avatarUri?.trim();
      if (avatarUri != null && avatarUri.isNotEmpty) {
        avatarUrisByName[cardName] = avatarUri;
      }
    }
    setState(() {
      _workspaceOverviewCharacterAvatarsByName =
          Map<String, String>.unmodifiable(avatarUrisByName);
    });
  }

  /// Applies one character-card update to workspace overview metadata.
  void _updateWorkspaceOverviewCharacter(core_proxy.CharacterCard card) {
    if (!mounted) {
      return;
    }
    final cardId = card.id.trim();
    final cardName = card.name.trim();
    if (cardId.isEmpty || cardName.isEmpty) {
      return;
    }
    final avatarUrisByName = Map<String, String>.of(
      _workspaceOverviewCharacterAvatarsByName,
    );
    final previousName = _workspaceOverviewCharacterNamesById[cardId];
    if (previousName != null) {
      avatarUrisByName.remove(previousName);
    }
    _workspaceOverviewCharacterNamesById[cardId] = cardName;
    final avatarUri = card.avatarUri?.trim();
    if (avatarUri != null && avatarUri.isNotEmpty) {
      avatarUrisByName[cardName] = avatarUri;
    }
    setState(() {
      _workspaceOverviewCharacterAvatarsByName =
          Map<String, String>.unmodifiable(avatarUrisByName);
    });
  }

  /// Removes one character-card entry from workspace overview metadata.
  void _removeWorkspaceOverviewCharacter(String cardName) {
    if (!mounted) {
      return;
    }
    final avatarUrisByName = Map<String, String>.of(
      _workspaceOverviewCharacterAvatarsByName,
    )..remove(cardName);
    setState(() {
      _workspaceOverviewCharacterAvatarsByName =
          Map<String, String>.unmodifiable(avatarUrisByName);
    });
  }

  /// Reports workspace overview character-card subscription errors.
  void _reportWorkspaceOverviewCharacterError(
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint(
      'Failed to watch workspace overview characters: $error\n$stackTrace',
    );
  }

  /// Refreshes mounted folders shown by the workspace overview.
  Future<void> _refreshWorkspaceOverviewMountedFolders() async {
    final loadGeneration = ++_workspaceOverviewMountedFoldersLoadGeneration;
    if (!widget.hasBoundWorkspace) {
      setState(() {
        _workspaceOverviewMountedFolders = const <WorkspaceFileEntry>[];
        _workspaceOverviewMountedFoldersLoading = false;
        _workspaceOverviewMountedFoldersError = null;
      });
      return;
    }

    setState(() {
      _workspaceOverviewMountedFoldersLoading = true;
      _workspaceOverviewMountedFoldersError = null;
    });
    try {
      final entries = await widget.onListWorkspaceFiles('');
      final mountedFolders = entries
          .where((entry) => entry.isDirectory)
          .toList(growable: false);
      if (!mounted ||
          loadGeneration != _workspaceOverviewMountedFoldersLoadGeneration) {
        return;
      }
      setState(() {
        _workspaceOverviewMountedFolders =
            List<WorkspaceFileEntry>.unmodifiable(mountedFolders);
        _workspaceOverviewMountedFoldersLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to refresh workspace overview folders: $error\n$stackTrace',
      );
      if (!mounted ||
          loadGeneration != _workspaceOverviewMountedFoldersLoadGeneration) {
        return;
      }
      setState(() {
        _workspaceOverviewMountedFoldersLoading = false;
        _workspaceOverviewMountedFoldersError = error.toString();
      });
    }
  }

  /// Converts mounted folder entries into overview display models.
  List<WorkspaceMountedFolder> _workspaceOverviewMountedFolderModels() {
    final mountedFolders = <WorkspaceMountedFolder>[];
    for (final entry in _workspaceOverviewMountedFolders) {
      final name = entry.name.trim();
      final path = entry.path.trim();
      final relativePath = entry.relativePath.trim();
      if (name.isEmpty || path.isEmpty || relativePath.isEmpty) {
        continue;
      }
      mountedFolders.add(
        WorkspaceMountedFolder(
          name: name,
          path: path,
          relativePath: relativePath,
        ),
      );
    }
    return List<WorkspaceMountedFolder>.unmodifiable(mountedFolders);
  }

  /// Creates a workspace overview snapshot with the current folder state.
  WorkspaceOverviewUsage _workspaceOverviewSnapshot({
    required String? workspaceName,
    required int conversationCount,
    required List<WorkspaceCharacterUsage> characterUsages,
  }) {
    final normalizedWorkspaceName = workspaceName?.trim();
    final mountedFoldersError = _workspaceOverviewMountedFoldersError?.trim();
    return WorkspaceOverviewUsage(
      workspaceName:
          normalizedWorkspaceName == null || normalizedWorkspaceName.isEmpty
          ? null
          : normalizedWorkspaceName,
      conversationCount: conversationCount,
      characterUsages: List<WorkspaceCharacterUsage>.unmodifiable(
        characterUsages,
      ),
      mountedFolders: _workspaceOverviewMountedFolderModels(),
      mountedFoldersLoading: _workspaceOverviewMountedFoldersLoading,
      mountedFoldersError:
          mountedFoldersError == null || mountedFoldersError.isEmpty
          ? null
          : mountedFoldersError,
    );
  }

  /// Builds role usage for the workspace bound to the current chat.
  WorkspaceOverviewUsage _workspaceOverviewUsage() {
    final currentChatId = widget.currentChatId?.trim();
    if (currentChatId == null || currentChatId.isEmpty) {
      return _workspaceOverviewSnapshot(
        workspaceName: null,
        conversationCount: 0,
        characterUsages: const <WorkspaceCharacterUsage>[],
      );
    }

    core_proxy.ChatHistoryListItem? currentHistory;
    for (final history in _workspaceOverviewHistories) {
      if (history.id == currentChatId) {
        currentHistory = history;
        break;
      }
    }
    if (currentHistory == null) {
      return _workspaceOverviewSnapshot(
        workspaceName: null,
        conversationCount: 0,
        characterUsages: const <WorkspaceCharacterUsage>[],
      );
    }

    final currentWorkspaceId = currentHistory.workspaceId?.trim();
    if (currentWorkspaceId == null || currentWorkspaceId.isEmpty) {
      return _workspaceOverviewSnapshot(
        workspaceName: currentHistory.workspaceName,
        conversationCount: 0,
        characterUsages: const <WorkspaceCharacterUsage>[],
      );
    }

    var conversationCount = 0;
    var order = 0;
    final characterCountsByName = <String, int>{};
    final firstOrderByName = <String, int>{};
    for (final history in _workspaceOverviewHistories) {
      final workspaceId = history.workspaceId?.trim();
      if (workspaceId != currentWorkspaceId) {
        continue;
      }
      conversationCount += 1;
      final characterName = history.characterCardName?.trim();
      if (characterName == null || characterName.isEmpty) {
        continue;
      }
      characterCountsByName[characterName] =
          (characterCountsByName[characterName] ?? 0) + 1;
      firstOrderByName.putIfAbsent(characterName, () => order);
      order += 1;
    }

    final usages = <WorkspaceCharacterUsage>[];
    for (final entry in characterCountsByName.entries) {
      usages.add(
        WorkspaceCharacterUsage(
          name: entry.key,
          avatarUri: _workspaceOverviewCharacterAvatarsByName[entry.key],
          conversationCount: entry.value,
        ),
      );
    }
    usages.sort((left, right) {
      final countComparison = right.conversationCount.compareTo(
        left.conversationCount,
      );
      if (countComparison != 0) {
        return countComparison;
      }
      final leftOrder = firstOrderByName[left.name]!;
      final rightOrder = firstOrderByName[right.name]!;
      return leftOrder.compareTo(rightOrder);
    });

    return _workspaceOverviewSnapshot(
      workspaceName: currentHistory.workspaceName,
      conversationCount: conversationCount,
      characterUsages: usages,
    );
  }

  void _selectTab(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _openSingletonTab(WorkspaceTab tab) {
    final existingIndex = _tabs.indexWhere((item) => item.kind == tab.kind);
    setState(() {
      if (existingIndex >= 0) {
        _tabs[existingIndex] = tab;
        _selectedIndex = existingIndex;
      } else {
        _tabs.add(tab);
        _selectedIndex = _tabs.length - 1;
      }
    });
  }

  void _openBrowserTab({
    String? url,
    String? localFilePath,
    String? workspaceHtmlPath,
    String? userAgent,
    Map<String, String>? headers,
  }) {
    unawaited(
      _openBrowserTabAsync(
        url: url,
        localFilePath: localFilePath,
        workspaceHtmlPath: workspaceHtmlPath,
        userAgent: userAgent,
        headers: headers,
      ),
    );
  }

  Future<void> _openBrowserTabAsync({
    String? url,
    String? localFilePath,
    String? workspaceHtmlPath,
    String? userAgent,
    Map<String, String>? headers,
  }) async {
    final htmlPath = workspaceHtmlPath?.trim();
    if (htmlPath != null && htmlPath.isNotEmpty) {
      await _browserViewStore.openWorkspaceHtmlTab(htmlPath, initialUrl: url);
    } else {
      final filePath = localFilePath?.trim();
      if (filePath != null && filePath.isNotEmpty) {
        await _browserViewStore.openLocalFileTab(filePath);
      } else {
        await _browserViewStore.openTab(
          url: url,
          userAgent: userAgent,
          headers: headers,
        );
      }
    }
    if (!mounted) {
      return;
    }
    _openBrowserWorkspaceTab();
  }

  void _openBrowserWorkspaceTab() {
    if (!mounted) {
      return;
    }
    final existingIndex = _tabs.indexWhere(
      (item) => item.kind == WorkspaceTabKind.browser,
    );
    setState(() {
      if (existingIndex >= 0) {
        _selectedIndex = existingIndex;
        return;
      }
      _tabs.add(
        const WorkspaceTab(
          kind: WorkspaceTabKind.browser,
          title: '',
          icon: Icons.public,
        ),
      );
      _selectedIndex = _tabs.length - 1;
    });
  }

  Future<WebVisitResponse> _openWebVisitTab(WebVisitRequest request) {
    final completer = Completer<WebVisitResponse>();
    _webVisitCompleters[request.requestId] = completer;
    final tab = WorkspaceTab(
      kind: WorkspaceTabKind.webVisit,
      title: _webVisitTabTitle(request),
      icon: Icons.travel_explore,
      webVisitRequest: request,
    );
    setState(() {
      _tabs.add(tab);
      _selectedIndex = _tabs.length - 1;
    });
    return completer.future;
  }

  String _webVisitTabTitle(WebVisitRequest request) {
    final uri = Uri.tryParse(request.url.trim());
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return 'visit_web';
  }

  Widget _buildTabContent(WorkspaceTab tab) {
    return WorkspaceTabContent(
      tab: tab,
      workspacePath: widget.workspacePath,
      workspaceUsage: _workspaceOverviewUsage(),
      terminalSessionCountListenable: _terminalSessionCount,
      browserSessionCountListenable: _browserSessionCount,
      onListWorkspaceFiles: widget.onListWorkspaceFiles,
      onListWorkspaceBindingDirectories:
          widget.onListWorkspaceBindingDirectories,
      onReadWorkspaceTextFile: widget.onReadWorkspaceTextFile,
      onReadWorkspaceFileBytes: widget.onReadWorkspaceFileBytes,
      onWriteWorkspaceFileBytes: widget.onWriteWorkspaceFileBytes,
      onOpenWorkspaceFile: widget.onOpenWorkspaceFile,
      onOpenFile: _openFileTab,
      onOpenFolder: _openMountedFolder,
      onAddFolder: _openWorkspaceBindingPickerTab,
      filesListingRevision: _filesListingRevision,
      onOpenTerminal: _createAndOpenTerminalSession,
      onOpenTerminalSessions: _showTerminalSessionPicker,
      onOpenBrowserSessions: _showBrowserSessionPicker,
      onOpenBrowser: _openBrowserTab,
      onFinishWebVisit: _finishWebVisitTab,
      onActivateCurrentTab: () => _selectWorkspaceTab(tab),
      onCloseCurrentTab: () => _closeWorkspaceTab(tab),
      onOpenWorkspaceCreator: _showCreateWorkspaceDialog,
      onBindWorkspace: _bindWorkspaceFolder,
      onChooseExistingWorkspace: _openWorkspaceBindingPickerTab,
      splitMarkdownContent: (content) => _coreClients.chatRuntimeHolderMain
          .splitMarkdownContent(content: content),
    );
  }

  /// Creates and opens a manual terminal session using the host-declared type.
  Future<void> _createAndOpenTerminalSession() async {
    final terminalInfo = await _terminalSessions.terminalInfo();
    if (!mounted) {
      return;
    }
    final terminal = await _selectTerminalType(terminalInfo);
    if (terminal == null) {
      return;
    }
    final workingDirectory = await _manualTerminalWorkingDirectory(
      terminal.terminal,
      terminal.terminalType,
    );
    final sessionId = await _terminalSessions.startPtySession(
      sessionName: _nextManualTerminalSessionName(),
      terminal: terminal.terminal,
      terminalType: terminal.terminalType,
      workingDirectory: workingDirectory,
      rows: 24,
      columns: 80,
    );
    final sessions = await _terminalSessions.listSessions();
    final session = sessions.firstWhere((item) => item.sessionId == sessionId);
    if (!mounted) {
      return;
    }
    _updateTerminalSessionEntries(sessions);
    _openTerminalSessionTab(session);
  }

  /// Prompts the user to choose one terminal implementation exposed by the active host.
  Future<core_proxy.RuntimeTerminalTypeInfo?> _selectTerminalType(
    core_proxy.RuntimeTerminalInfo terminalInfo,
  ) {
    return showDialog<core_proxy.RuntimeTerminalTypeInfo>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final availableTypes = terminalInfo.types
            .where((item) => item.available)
            .toList(growable: false);
        return AlertDialog(
          title: const Text('选择终端类型'),
          content: SizedBox(
            width: 460,
            child: availableTypes.isEmpty
                ? Text(
                    '当前平台没有可用的终端类型。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : RadioGroup<String>(
                    groupValue:
                        '${terminalInfo.terminal}\u0000${terminalInfo.terminalType}',
                    onChanged: (value) {
                      final selected = availableTypes.firstWhere(
                        (item) =>
                            '${item.terminal}\u0000${item.terminalType}' ==
                            value,
                      );
                      Navigator.of(context).pop(selected);
                    },
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: terminalInfo.types.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = terminalInfo.types[index];
                        return ListTile(
                          enabled: item.available,
                          leading: Radio<String>(
                            value: '${item.terminal}\u0000${item.terminalType}',
                            enabled: item.available,
                          ),
                          title: Text(
                            '${item.terminal} / ${item.terminalType}',
                          ),
                          subtitle: Text(item.description),
                          onTap: item.available
                              ? () => Navigator.of(context).pop(item)
                              : null,
                        );
                      },
                    ),
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  /// Resolves the initial directory supported by the selected terminal host.
  Future<String> _manualTerminalWorkingDirectory(
    String terminal,
    String terminalType,
  ) async {
    if (terminal == 'v86') {
      return '/';
    }
    if (!widget.hasBoundWorkspace) {
      return const GeneratedCoreProxyClients(
        ProxyCoreRuntimeBridge(),
      ).application.operitRootPath();
    }
    final workspaceDirectory = widget.workspacePath?.trim();
    if (workspaceDirectory == null || workspaceDirectory.isEmpty) {
      throw StateError('工作区路径为空');
    }
    return workspaceDirectory;
  }

  String _nextManualTerminalSessionName() {
    final manualCount = _terminalSessionEntries
        .where((session) => session.sessionName.trim().startsWith('手动终端'))
        .length;
    return '手动终端 ${manualCount + 1}';
  }

  Future<void> _showTerminalSessionPicker() async {
    final sessions = await _terminalSessions.listSessions();
    if (!mounted) {
      return;
    }
    _updateTerminalSessionEntries(sessions);
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        var dialogSessions = sessions;
        final closingSessionIds = <String>{};
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> closeSession(
              WorkspaceTerminalSessionInfo session,
            ) async {
              setDialogState(() {
                closingSessionIds.add(session.sessionId);
              });
              _removeTerminalTabsForSession(session.sessionId);
              await _closeManualTerminalSession(session.sessionId);
              final updatedSessions = await _terminalSessions.listSessions();
              if (!mounted) {
                return;
              }
              _updateTerminalSessionEntries(updatedSessions);
              setDialogState(() {
                closingSessionIds.remove(session.sessionId);
                dialogSessions = updatedSessions;
              });
            }

            return AlertDialog(
              title: const Text('终端会话'),
              contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              content: SizedBox(
                width: 520,
                child: dialogSessions.isEmpty
                    ? Text(
                        '当前没有终端会话',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 420),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: dialogSessions.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final session = dialogSessions[index];
                            final isClosing = closingSessionIds.contains(
                              session.sessionId,
                            );
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(session.title),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _terminalSessionSubtitle(session),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: '结束进程',
                                onPressed: isClosing
                                    ? null
                                    : () => closeSession(session),
                                icon: isClosing
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.stop_circle_outlined),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _openTerminalSessionTab(session);
                              },
                            );
                          },
                        ),
                      ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showBrowserSessionPicker() async {
    final sessions = await _browserSessions.listSessions();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        var dialogSessions = sessions;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> closeSession(String sessionId) async {
              await _browserSessions.close(sessionId);
              final updated = await _browserSessions.listSessions();
              if (!context.mounted) {
                return;
              }
              setDialogState(() {
                dialogSessions = updated;
              });
            }

            return AlertDialog(
              title: const Text('浏览器会话'),
              contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              content: SizedBox(
                width: 520,
                child: dialogSessions.isEmpty
                    ? Text(
                        '当前没有浏览器会话',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 420),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: dialogSessions.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final session = dialogSessions[index];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(session.title),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _browserSessionSubtitle(session),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: '关闭会话',
                                onPressed: () {
                                  unawaited(closeSession(session.sessionId));
                                },
                                icon: const Icon(Icons.close),
                              ),
                              onTap: () async {
                                Navigator.of(context).pop();
                                await _browserViewStore.attachSession(session);
                                if (!mounted) {
                                  return;
                                }
                                _openBrowserWorkspaceTab();
                                _browserViewStore.selectSession(
                                  session.sessionId,
                                );
                              },
                            );
                          },
                        ),
                      ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _updateTerminalSessionEntries(
    List<WorkspaceTerminalSessionInfo> sessions,
  ) {
    _terminalSessionEntries = sessions;
    _terminalSessionCount.value = sessions.length;
  }

  /// Updates terminal session entries from the runtime snapshot.
  Future<void> _refreshTerminalSessionEntries() async {
    final sessions = await _terminalSessions.listSessions();
    if (!mounted) {
      return;
    }
    _updateTerminalSessionEntries(sessions);
  }

  /// Updates the browser session counter from the owner registry.
  void _handleBrowserSessionRegistryChanged() {
    _browserSessionCount.value = _browserSessionRegistry.sessions.length;
  }

  void _removeTerminalTabsForSession(String sessionId) {
    final selectedTab = _tabs[_selectedIndex];
    setState(() {
      _tabs.removeWhere((tab) => tab.terminalSessionId == sessionId);
      final preservedIndex = _tabs.indexOf(selectedTab);
      if (preservedIndex >= 0) {
        _selectedIndex = preservedIndex;
      } else {
        _selectedIndex = _selectedIndex.clamp(0, _tabs.length - 1).toInt();
      }
    });
  }

  String _terminalSessionSubtitle(WorkspaceTerminalSessionInfo session) {
    final workingDir = session.workingDir.trim();
    const prefix = 'PTY';
    if (workingDir.isNotEmpty) {
      return 'UUID · ${session.sessionId}\n$prefix · $workingDir';
    }
    return 'UUID · ${session.sessionId}\n$prefix · ${session.terminalType}';
  }

  String _browserSessionSubtitle(core_proxy.RuntimeBrowserSessionInfo session) {
    return 'UUID · ${session.sessionId}\n${session.currentUrl}';
  }

  void _openTerminalSessionTab(WorkspaceTerminalSessionInfo session) {
    final existingIndex = _tabs.indexWhere(
      (tab) => tab.terminalSessionId == session.sessionId,
    );
    final tab = WorkspaceTab(
      kind: WorkspaceTabKind.terminal,
      title: session.title,
      icon: Icons.terminal,
      terminalSessionId: session.sessionId,
      terminalType: session.terminalType,
      terminalWorkingDir: session.workingDir,
    );
    setState(() {
      if (existingIndex >= 0) {
        _tabs[existingIndex] = tab;
        _selectedIndex = existingIndex;
      } else {
        _tabs.add(tab);
        _selectedIndex = _tabs.length - 1;
      }
    });
  }

  /// Shows the workspace creation dialog without opening a setup tab.
  void _showCreateWorkspaceDialog() {
    final nameController = TextEditingController();
    var dialogBusy = false;
    String? dialogError;
    final dialogFuture = showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final l10n = AppLocalizations.of(context)!;
            Future<void> submitCreateWorkspace() async {
              if (dialogBusy) {
                return;
              }
              final name = nameController.text.trim();
              if (name.isEmpty) {
                setDialogState(() {
                  dialogError = l10n.workspaceNameHint;
                });
                return;
              }
              setDialogState(() {
                dialogBusy = true;
                dialogError = null;
              });
              try {
                await _createWorkspace(name);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              } catch (error, stackTrace) {
                debugPrint('Workspace creation failed: $error\n$stackTrace');
                if (dialogContext.mounted) {
                  setDialogState(() {
                    dialogError = error.toString();
                  });
                }
              } finally {
                if (dialogContext.mounted) {
                  setDialogState(() {
                    dialogBusy = false;
                  });
                }
              }
            }

            return AlertDialog(
              title: Text(l10n.workspaceCreateTitle),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      TextField(
                        controller: nameController,
                        autofocus: true,
                        enabled: !dialogBusy,
                        decoration: InputDecoration(
                          labelText: l10n.workspaceNameLabel,
                          hintText: l10n.workspaceNameHint,
                        ),
                      ),
                      if (dialogError != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          dialogError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: dialogBusy
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: dialogBusy
                      ? null
                      : () {
                          unawaited(submitCreateWorkspace());
                        },
                  child: Text(l10n.bind),
                ),
              ],
            );
          },
        );
      },
    );
    unawaited(dialogFuture.whenComplete(nameController.dispose));
  }

  /// Opens the file tree for one mounted workspace folder.
  void _openMountedFolder(WorkspaceMountedFolder folder) {
    final relativePath = folder.relativePath.trim();
    final title = folder.name.trim();
    setState(() {
      _workspaceTabIdentitySequence += 1;
      _tabs.add(
        WorkspaceTab(
          kind: WorkspaceTabKind.files,
          title: title,
          icon: Icons.folder_outlined,
          filePath: relativePath,
          identityToken: 'mounted-folder-$_workspaceTabIdentitySequence',
        ),
      );
      _selectedIndex = _tabs.length - 1;
    });
  }

  /// Opens the workspace folder picker for binding or mounting.
  void _openWorkspaceBindingPickerTab() {
    final l10n = AppLocalizations.of(context)!;
    _openSingletonTab(
      WorkspaceTab(
        kind: WorkspaceTabKind.workspacePicker,
        title: widget.hasBoundWorkspace ? l10n.workspaceAddFolderTitle : '',
        icon: Icons.folder_open_outlined,
      ),
    );
  }

  /// Binds or mounts the selected folder, then shows the workspace file tree.
  Future<void> _bindWorkspaceFolder(String workspace) async {
    await widget.onBindWorkspace(workspace);
    if (!mounted) {
      return;
    }
    if (widget.hasBoundWorkspace) {
      unawaited(_refreshWorkspaceOverviewMountedFolders());
    }
    setState(() {
      _filesListingRevision += 1;
    });
    _replacePickerTabWithFilesTab();
  }

  /// Creates a named workspace and switches the workspace panel back to files.
  Future<void> _createWorkspace(String name) async {
    await widget.onCreateWorkspace(name);
    if (!mounted) {
      return;
    }
    if (widget.hasBoundWorkspace) {
      unawaited(_refreshWorkspaceOverviewMountedFolders());
    }
    setState(() {
      _filesListingRevision += 1;
    });
    _replacePickerTabWithFilesTab();
  }

  /// Replaces the workspace picker tab with the workspace files tab.
  void _replacePickerTabWithFilesTab() {
    final targetIndex = _tabs.indexWhere(
      (tab) => tab.kind == WorkspaceTabKind.workspacePicker,
    );
    if (targetIndex < 0) {
      return;
    }
    final selectedTab = _tabs[_selectedIndex];
    final selectedWasTarget =
        selectedTab.kind == WorkspaceTabKind.workspacePicker;
    setState(() {
      _tabs.removeWhere(
        (tab) => tab.kind == WorkspaceTabKind.workspacePicker,
      );
      var filesIndex = _tabs.indexWhere(
        (tab) => tab.kind == WorkspaceTabKind.files,
      );
      if (filesIndex < 0) {
        _tabs.add(
          const WorkspaceTab(
            kind: WorkspaceTabKind.files,
            title: '',
            icon: Icons.folder_outlined,
          ),
        );
        filesIndex = _tabs.length - 1;
      }
      if (selectedWasTarget) {
        _selectedIndex = filesIndex;
        return;
      }
      final preservedIndex = _tabs.indexOf(selectedTab);
      _selectedIndex = preservedIndex >= 0
          ? preservedIndex
          : _selectedIndex.clamp(0, _tabs.length - 1).toInt();
    });
  }

  /// Builds a stable workspace tab identity for diffing tab lists.
  String _tabIdentity(WorkspaceTab tab) {
    return <String>[
      tab.kind.name,
      tab.filePath ?? '',
      tab.absolutePath ?? '',
      tab.url ?? '',
      tab.workspaceHtmlPath ?? '',
      tab.webVisitRequest?.requestId ?? '',
      tab.terminalSessionId ?? '',
      tab.identityToken,
      tab.title,
    ].join('|');
  }

  void _closeTab(int index) {
    if (index <= 0 || index >= _tabs.length) {
      return;
    }
    final tab = _tabs[index];
    setState(() {
      _tabs.removeAt(index);
      if (_selectedIndex == index) {
        _selectedIndex = (index - 1).clamp(0, _tabs.length - 1);
      } else if (_selectedIndex > index) {
        _selectedIndex -= 1;
      }
    });
    if (tab.kind == WorkspaceTabKind.terminal) {
      final sessionId = tab.terminalSessionId;
      if (sessionId != null && sessionId.trim().isNotEmpty) {
        unawaited(_closeManualTerminalSession(sessionId));
      }
    }
    if (tab.kind == WorkspaceTabKind.webVisit) {
      final request = tab.webVisitRequest;
      if (request != null) {
        _completeWebVisitRequest(
          request.requestId,
          WebVisitResponse(
            requestId: request.requestId,
            success: false,
            error: 'visit_web cancelled',
          ),
        );
      }
    }
  }

  void _selectWorkspaceTab(WorkspaceTab tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) {
      return;
    }
    setState(() {
      _selectedIndex = index;
    });
  }

  void _closeWorkspaceTab(WorkspaceTab tab) {
    final index = _tabs.indexOf(tab);
    if (index <= 0) {
      return;
    }
    _closeTab(index);
  }

  void _finishWebVisitTab(WorkspaceTab tab, WebVisitResponse response) {
    final request = tab.webVisitRequest;
    if (request == null) {
      return;
    }
    _completeWebVisitRequest(request.requestId, response);
    final index = _tabs.indexOf(tab);
    if (index > 0) {
      setState(() {
        _tabs.removeAt(index);
        if (_selectedIndex == index) {
          _selectedIndex = (index - 1).clamp(0, _tabs.length - 1);
        } else if (_selectedIndex > index) {
          _selectedIndex -= 1;
        }
      });
    }
  }

  void _completeWebVisitRequest(String requestId, WebVisitResponse response) {
    final completer = _webVisitCompleters.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
  }

  /// Closes the host PTY after removed terminal widgets dispose listeners.
  Future<void> _closeManualTerminalSession(String sessionId) async {
    await WidgetsBinding.instance.endOfFrame;
    await _terminalSessions.closePtySession(sessionId);
  }

  Future<void> _openFileTab(WorkspaceFileEntry entry) async {
    final previewKind = workspacePreviewKindForPath(entry.path);
    var content = '';
    if (previewKind == WorkspaceFilePreviewKind.text ||
        previewKind == WorkspaceFilePreviewKind.markdown ||
        previewKind == WorkspaceFilePreviewKind.html) {
      content = await widget.onReadWorkspaceTextFile(entry.relativePath);
    }

    if (!mounted) {
      return;
    }

    final existingIndex = _tabs.indexWhere(
      (item) => item.filePath == entry.path,
    );
    final tab = WorkspaceTab(
      kind: WorkspaceTabKind.filePreview,
      title: entry.name,
      icon: workspacePreviewIconForKind(previewKind),
      filePath: entry.relativePath,
      absolutePath: entry.path,
      fileContent: content,
      previewKind: previewKind,
    );
    setState(() {
      if (existingIndex >= 0) {
        _tabs[existingIndex] = tab;
        _selectedIndex = existingIndex;
      } else {
        _tabs.add(tab);
        _selectedIndex = _tabs.length - 1;
      }
    });
  }
}
