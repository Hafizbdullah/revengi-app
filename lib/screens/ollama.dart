import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:ollama_dart/ollama_dart.dart';
import 'package:dio/dio.dart';
import 'package:revengi/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revengi/utils/platform.dart';

enum AIProvider { local, cloud }

class OllamaChatScreen extends StatefulWidget {
  const OllamaChatScreen({super.key});

  @override
  OllamaChatScreenState createState() => OllamaChatScreenState();
}

class OllamaChatScreenState extends State<OllamaChatScreen>
    with SingleTickerProviderStateMixin {
  late final OllamaClient client;
  TabController? _tabController;

  // Provider settings
  AIProvider currentProvider = AIProvider.local;
  String cloudBaseUrl = 'https://api.revengi.in';
  String cloudApiKey = '';
  List<String> cloudModels = [];
  bool isLoadingCloudModels = false;
  String? cloudModelsError;

  // Local Ollama settings
  List<String> localModels = [];
  String? selectedModel;
  bool pulling = false;
  double pullProgress = 0.0;
  String? pullStatusText;
  bool chatInputEnabled = true;

  String systemMessage =
      "You are an AI coding & helpful assistant. Your main goal is to follow the USER's instructions at each message. If you are unsure about the answer to the USER's request or how to satiate their request, you should gather more information. This can be done by asking the USER for more information. Bias towards not asking the user for help if you can find the answer yourself. You MUST reply in markdown format. You MUST use code blocks for code. Don't use emojis un-necessarily.";

  final List<ChatMessage> messages = [];
  final TextEditingController _inputController = TextEditingController();
  StreamSubscription<GenerateChatCompletionResponse>? _chatStreamSub;
  StreamSubscription? _cloudChatStreamSub;
  Timer? _typingTimer;
  int _typingDotCount = 1;

  // Default remote catalog for Local Ollama
  final List<String> remoteCatalog = [
    'qwen3:0.6b-q4_K_M',
    'qwen2.5-coder:1.5b',
    'gemma3:1b',
    'llama3.2:1b-instruct-q4_1',
  ];

  // Default cloud models catalog
  final List<String> defaultCloudModels = [
    'llama3.2',
    'qwen3',
    'gemma3',
    'mistral',
    'phi3',
  ];

  Map<String, String?> remoteModelSizes = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSettings();
    _initializeClient();
    _fetchRemoteModelSizes();
  }

  @override
  void dispose() {
    _chatStreamSub?.cancel();
    _cloudChatStreamSub?.cancel();
    _typingTimer?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final providerIndex = prefs.getInt('aiProvider') ?? 0;
    setState(() {
      currentProvider = AIProvider.values[providerIndex];
      cloudBaseUrl = prefs.getString('cloudBaseUrl') ?? 'https://api.revengi.in';
      cloudApiKey = prefs.getString('cloudApiKey') ?? '';
      selectedModel = prefs.getString('lastSelectedModel');
    });
    if (currentProvider == AIProvider.cloud) {
      await _fetchCloudModels();
    } else {
      _initializeClient();
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('aiProvider', currentProvider.index);
    await prefs.setString('cloudBaseUrl', cloudBaseUrl);
    await prefs.setString('cloudApiKey', cloudApiKey);
    if (selectedModel != null) {
      await prefs.setString('lastSelectedModel', selectedModel!);
    }
  }

  Future<void> _initializeClient() async {
    if (currentProvider == AIProvider.cloud) {
      return;
    }
    String baseUrl = await _getLocalBaseUrl();
    try {
      client = OllamaClient(baseUrl: baseUrl);
      await _loadLocalModels();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.ollamaInitializeError(e.toString()),
            ),
          ),
        );
        setState(() {
          chatInputEnabled = false;
        });
      }
    }
  }

  Future<String> _getLocalBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('ollamaBaseUrl') ?? 'http://localhost:11434/api';
  }

  Future<void> _loadLocalModels() async {
    try {
      final res = await client.listModels();
      if (mounted) {
        setState(() {
          localModels =
              res.models!.map((m) => m.model).whereType<String>().toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchRemoteModelSizes() async {
    if (isWeb()) return;
    final prefs = await SharedPreferences.getInstance();
    for (final model in remoteCatalog) {
      String? size = prefs.getString('model_size_$model');
      if (size == null) {
        size = await _getModelSize(model);
        if (size != null) {
          await prefs.setString('model_size_$model', size);
        }
      }
      if (mounted) {
        setState(() {
          remoteModelSizes[model] = size;
        });
      }
    }
  }

  Future<String?> _getModelSize(String model) async {
    if (isWeb()) return null;
    final dio = Dio();
    final url = 'https://ollama.com/library/${Uri.encodeComponent(model)}';
    try {
      final response = await dio.get(url);
      if (response.statusCode == 200) {
        final html = response.data as String;
        final regex = RegExp(
          r'<div class="flex items-center justify-between bg-neutral-50 px-4 py-3 text-xs text-neutral-900">[\s\S]*?<p>.*?· (.*?)<\/p>',
          multiLine: true,
        );
        final match = regex.firstMatch(html);
        if (match != null && match.groupCount >= 1) {
          return match.group(1);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchCloudModels() async {
    if (currentProvider != AIProvider.cloud) return;
    setState(() {
      isLoadingCloudModels = true;
      cloudModelsError = null;
    });
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: cloudBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Authorization': 'Bearer $cloudApiKey'},
        ),
      );
      final response = await dio.get('/v1/models');
      if (response.statusCode == 200) {
        final List<dynamic> models = response.data['data'] ?? [];
        if (mounted) {
          setState(() {
            cloudModels = models
                .map((m) => m['id']?.toString() ?? '')
                .where((m) => m.isNotEmpty)
                .toList();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          cloudModels = List.from(defaultCloudModels);
          cloudModelsError =
              AppLocalizations.of(context)!.failedToFetchModels(e.toString());
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoadingCloudModels = false;
        });
      }
    }
  }

  Future<void> _switchProvider(AIProvider provider) async {
    if (currentProvider == provider) return;
    setState(() {
      currentProvider = provider;
      chatInputEnabled = true;
    });
    await _saveSettings();
    if (provider == AIProvider.local) {
      await _initializeClient();
      await _loadLocalModels();
    } else {
      await _fetchCloudModels();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _saveCloudSettings() async {
    await _saveSettings();
    await _fetchCloudModels();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsSaved),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _testCloudConnection() async {
    if (cloudBaseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.enterBaseUrl),
        ),
      );
      return;
    }
    setState(() {
      isLoadingCloudModels = true;
    });
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: cloudBaseUrl,
          connectTimeout: const Duration(seconds: 5),
          headers: {
            if (cloudApiKey.isNotEmpty) 'Authorization': 'Bearer $cloudApiKey',
          },
        ),
      );
      final response = await dio.get('/v1/models');
      if (response.statusCode == 200) {
        await _fetchCloudModels();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.connectionSuccessful),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.connectionFailed(
                  response.statusCode.toString(),
                ),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.connectionFailed(e.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoadingCloudModels = false;
        });
      }
    }
  }

  Future<void> _pullModel(String model) async {
    if (currentProvider != AIProvider.local) return;
    final localizations = AppLocalizations.of(context)!;
    if (mounted) {
      setState(() {
        pulling = true;
        pullProgress = 0.0;
        pullStatusText = null;
      });
    }

    try {
      final stream = client.pullModelStream(
        request: PullModelRequest(model: model),
      );

      int? total;
      int? completed;

      await for (var status in stream) {
        if (mounted) {
          setState(() {
            total = status.total;
            completed = status.completed;
            if (total != null && completed != null && total! > 0) {
              pullProgress = completed! / total!;
              pullStatusText =
                  '${AppLocalizations.of(context)!.downloading} ${(pullProgress * 100).toStringAsFixed(0)}%';
            } else {
              pullProgress = 0.0;
              pullStatusText = status.status?.toString() ?? '';
            }
          });
        }
      }
      await _loadLocalModels();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              localizations.failedToPullModel("Is Ollama running?"),
            ),
          ),
        );
        setState(() {
          pullStatusText = localizations.failedToPullModel(e.toString());
          chatInputEnabled = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          pulling = false;
        });
      }
    }
  }

  Future<void> _deleteModel(String model) async {
    if (currentProvider != AIProvider.local) return;
    final dio = Dio();
    final baseUrl = await _getLocalBaseUrl();
    final url = '$baseUrl/delete';

    try {
      final response = await dio.delete(url, data: {'model': model});

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppLocalizations.of(context)!.modelDeleted}: $model')),
          );
        }
        setState(() {
          localModels.remove(model);
          if (selectedModel == model) selectedModel = null;
        });
      } else if (response.statusCode == 404) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppLocalizations.of(context)!.modelNotFound}: $model')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${AppLocalizations.of(context)!.failedToDeleteModel}: $model')),
          );
        }
      }
    } catch (_) {}
  }

  void _startTypingAnimation() {
    _typingDotCount = 1;
    _typingTimer?.cancel();
    _typingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {
          _typingDotCount = _typingDotCount % 3 + 1;
          if (messages.isNotEmpty && !messages.last.fromUser) {
            messages.last = messages.last.copyWith(text: '.' * _typingDotCount);
          }
        });
      }
    });
  }

  void _stopTypingAnimation() {
    _typingTimer?.cancel();
    _typingTimer = null;
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty || selectedModel == null || !chatInputEnabled) return;

    setState(() => chatInputEnabled = false);
    _inputController.clear();
    final userMsg = ChatMessage(text: text, fromUser: true);
    setState(() => messages.add(userMsg));

    setState(() => messages.add(ChatMessage(text: '.', fromUser: false)));
    _startTypingAnimation();

    if (currentProvider == AIProvider.local) {
      _sendLocalMessage(text);
    } else {
      _sendCloudMessage(text);
    }
  }

  void _sendLocalMessage(String text) {
    final history = [
      Message(role: MessageRole.system, content: systemMessage),
      ...messages
          .where(
            (m) =>
                !(m.text == '.' || m.text == '..' || m.text == '...') ||
                m.fromUser,
          )
          .map(
            (m) => Message(
              role: m.fromUser ? MessageRole.user : MessageRole.assistant,
              content: m.text,
            ),
          ),
      Message(role: MessageRole.user, content: text),
    ];

    _chatStreamSub?.cancel();
    _chatStreamSub = client
        .generateChatCompletionStream(
          request: GenerateChatCompletionRequest(
            model: selectedModel!,
            messages: history,
            keepAlive: 1,
          ),
        )
        .listen(
          (res) {
            if (mounted) {
              final chunk = res.message.content;
              if (messages.isNotEmpty && !messages.last.fromUser) {
                _stopTypingAnimation();
                setState(
                  () => messages.last = messages.last.copyWith(
                    text:
                        messages.last.text == '.' ||
                                messages.last.text == '..' ||
                                messages.last.text == '...'
                            ? chunk
                            : messages.last.text + chunk,
                  ),
                );
              } else {
                _stopTypingAnimation();
                setState(
                  () => messages.add(ChatMessage(text: chunk, fromUser: false)),
                );
              }
            }
          },
          onDone: () {
            if (mounted) {
              _stopTypingAnimation();
              setState(() {
                chatInputEnabled = true;
                if (messages.isNotEmpty && !messages.last.fromUser) {
                  messages.last = messages.last.copyWith(
                    text: messages.last.text,
                    fromUser: false,
                  );
                }
              });
            }
          },
          onError: (err) {
            if (mounted) {
              _stopTypingAnimation();
              setState(() => chatInputEnabled = true);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${AppLocalizations.of(context)!.failedToSendMessage}: $err')),
              );
            }
          },
        );
  }

  void _sendCloudMessage(String text) async {
    final history = [
      {'role': 'system', 'content': systemMessage},
      ...messages
          .where(
            (m) =>
                !(m.text == '.' || m.text == '..' || m.text == '...') ||
                m.fromUser,
          )
          .map(
            (m) => {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
          ),
      {'role': 'user', 'content': text},
    ];

    final dio = Dio(
      BaseOptions(
        baseUrl: cloudBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          if (cloudApiKey.isNotEmpty) 'Authorization': 'Bearer $cloudApiKey',
          'Content-Type': 'application/json',
        },
      ),
    );

    _cloudChatStreamSub?.cancel();

    try {
      final response = await dio.post<ResponseBody>(
        '/v1/chat/completions',
        data: {
          'model': selectedModel,
          'messages': history,
          'stream': true,
        },
        options: Options(responseType: ResponseType.stream),
      );

      _cloudChatStreamSub = response.data?.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (!mounted) return;
          if (line.startsWith('data: ')) {
            final dataStr = line.substring(6).trim();
            if (dataStr == '[DONE]') return;
            try {
              final json = jsonDecode(dataStr);
              final chunk = json['choices']?[0]?['delta']?['content'];
              if (chunk != null && chunk.isNotEmpty) {
                _stopTypingAnimation();
                setState(() {
                  if (messages.isNotEmpty && !messages.last.fromUser) {
                    messages.last = messages.last.copyWith(
                      text: messages.last.text == '.' ||
                              messages.last.text == '..' ||
                              messages.last.text == '...'
                          ? chunk
                          : messages.last.text + chunk,
                    );
                  } else {
                    messages.add(ChatMessage(text: chunk, fromUser: false));
                  }
                });
              }
            } catch (_) {}
          }
        },
        onDone: () {
          if (mounted) {
            _stopTypingAnimation();
            setState(() => chatInputEnabled = true);
          }
        },
        onError: (err) {
          if (mounted) {
            _stopTypingAnimation();
            setState(() => chatInputEnabled = true);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${AppLocalizations.of(context)!.failedToSendMessage}: $err')),
            );
          }
        },
      );
    } catch (e) {
      if (mounted) {
        _stopTypingAnimation();
        setState(() => chatInputEnabled = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppLocalizations.of(context)!.failedToSendMessage}: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(localizations.aiChat),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: localizations.models),
            if (currentProvider == AIProvider.cloud)
              Tab(text: localizations.cloudSettings)
            else
              Tab(text: localizations.chat),
            Tab(text: localizations.chat),
          ],
        ),
        actions: [
          PopupMenuButton<AIProvider>(
            icon: const Icon(Icons.more_vert),
            onSelected: _switchProvider,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: AIProvider.local,
                child: Row(
                  children: [
                    Icon(
                      currentProvider == AIProvider.local
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: currentProvider == AIProvider.local
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(localizations.localProvider),
                  ],
                ),
              ),
              PopupMenuItem(
                value: AIProvider.cloud,
                child: Row(
                  children: [
                    Icon(
                      currentProvider == AIProvider.cloud
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: currentProvider == AIProvider.cloud
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(localizations.cloudProvider),
                  ],
                ),
              ),
            ],
          ),
          if (_tabController?.index == 2)
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: localizations.systemMessage,
              onPressed: () async {
                final controller = TextEditingController(text: systemMessage);
                final result = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(localizations.setSystemMessage),
                    content: TextField(
                      controller: controller,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: localizations.systemMessage,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(localizations.cancel),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          controller.text.trim(),
                        ),
                        child: Text(localizations.save),
                      ),
                    ],
                  ),
                );
                if (result != null && result.isNotEmpty) {
                  setState(() => systemMessage = result);
                }
              },
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          if (currentProvider == AIProvider.local)
            _buildLocalModelsTab()
          else
            _buildCloudModelsTab(),
          if (currentProvider == AIProvider.cloud) _buildCloudSettingsTab(),
          _buildChatTab(),
        ],
      ),
    );
  }

  Widget _buildLocalModelsTab() {
    final hasLocalModels = localModels.isNotEmpty;
    final localizations = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hasLocalModels) ...[
                      Text(
                        localizations.downloadedModels,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: localModels.length,
                        itemBuilder: (_, i) {
                          final m = localModels[i];
                          final selected = m == selectedModel;
                          return Card(
                            color: selected ? Colors.blue[50] : null,
                            child: ListTile(
                              title: Text(m),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.delete),
                                    onPressed: () => _deleteModel(m),
                                  ),
                                  if (selected)
                                    const Icon(
                                      Icons.check_circle,
                                      color: Colors.blue,
                                    ),
                                ],
                              ),
                              selected: selected,
                              onTap: () {
                                setState(() => selectedModel = m);
                                _tabController!.animateTo(2);
                                _saveSettings();
                              },
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                    ],
                    Text(
                      localizations.downloadModel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 260,
                      child: ListView.builder(
                        itemCount: remoteCatalog.length,
                        itemBuilder: (_, i) {
                          final model = remoteCatalog[i];
                          final size = remoteModelSizes[model];
                          return Card(
                            child: ListTile(
                              title: Row(
                                children: [
                                  Expanded(child: Text(model)),
                                  if (size != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '($size)',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              trailing: pulling && selectedModel == model
                                  ? SizedBox(
                                      width: 200,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: LinearProgressIndicator(
                                              value: pullProgress > 0
                                                  ? pullProgress
                                                  : null,
                                            ),
                                          ),
                                          if (pullStatusText != null) ...[
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                pullStatusText!,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(Icons.download),
                                      onPressed: pulling
                                          ? null
                                          : () async {
                                            selectedModel = model;
                                            await _pullModel(model);
                                          },
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${AppLocalizations.of(context)!.or}\n${AppLocalizations.of(context)!.provideModelFrom} https://ollama.com/library',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: InputDecoration(
                              labelText: localizations.enterModelName,
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (value) {
                              selectedModel = value.trim();
                            },
                            onSubmitted: (value) async {
                              if (value.trim().isNotEmpty && !pulling) {
                                final modelName = value.trim();
                                bool isOnAndroid = isAndroid();
                                if (isOnAndroid) {
                                  setState(() {
                                    pulling = true;
                                    pullStatusText =
                                        localizations.fetchingModelInfo;
                                  });
                                }
                                String? sizeStr = remoteModelSizes[modelName];
                                if (sizeStr == null) {
                                  sizeStr = await _getModelSize(modelName);
                                  if (sizeStr != null) {
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setString(
                                      'model_size_$modelName',
                                      sizeStr,
                                    );
                                    setState(() {
                                      remoteModelSizes[modelName] = sizeStr;
                                    });
                                  }
                                }
                                bool proceed = true;
                                if (sizeStr != null && isOnAndroid) {
                                  setState(() {
                                    pullStatusText =
                                        localizations.checkingDeviceRam;
                                  });
                                  double sizeGB = 0;
                                  final gbMatch = RegExp(
                                    r'([\d.]+)\s*GB',
                                    caseSensitive: false,
                                  ).firstMatch(sizeStr);
                                  final mbMatch = RegExp(
                                    r'([\d.]+)\s*MB',
                                    caseSensitive: false,
                                  ).firstMatch(sizeStr);
                                  if (gbMatch != null) {
                                    sizeGB = double.tryParse(
                                          gbMatch.group(1) ?? '0',
                                        ) ??
                                        0;
                                  } else if (mbMatch != null) {
                                    sizeGB = (double.tryParse(
                                          mbMatch.group(1) ?? '0',
                                        ) ??
                                        0) /
                                        1024.0;
                                  }
                                  final ramBytes =
                                      await DeviceInfo.getTotalRAM();
                                  final ramGB =
                                      ramBytes / (1024 * 1024 * 1024);
                                  if (sizeGB > 0 &&
                                      ramGB > 0 &&
                                      sizeGB > ramGB * 0.75) {
                                    setState(() {
                                      pullStatusText = null;
                                      pulling = false;
                                    });
                                    if (!context.mounted) return;
                                    proceed = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: Text(
                                              localizations.largeModelWarning,
                                            ),
                                            content: Text(
                                              '${AppLocalizations.of(context)!.modelSizeWarning} $sizeStr (${ramGB.toStringAsFixed(2)} GB RAM). ${AppLocalizations.of(context)!.mayCauseIssues}',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context, false),
                                                child: Text(localizations.cancel),
                                              ),
                                              ElevatedButton(
                                                onPressed: () =>
                                                    Navigator.pop(context, true),
                                                child: Text(localizations.proceed),
                                              ),
                                            ],
                                          ),
                                        ) ??
                                        false;
                                  } else {
                                    setState(() {
                                      pullStatusText = null;
                                      pulling = false;
                                    });
                                  }
                                }
                                if (proceed) {
                                  setState(() {
                                    selectedModel = modelName;
                                    pulling = true;
                                  });
                                  await _pullModel(selectedModel!);
                                } else if (isOnAndroid) {
                                  setState(() {
                                    pullStatusText = null;
                                    pulling = false;
                                  });
                                }
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Builder(
                          builder: (context) => IconButton(
                            icon: const Icon(Icons.open_in_new),
                            tooltip: localizations.openOllamaLibrary,
                            onPressed: () async {
                              final url = Uri.parse(
                                'https://ollama.com/library/${selectedModel ?? ''}',
                              );
                              if (await canLaunchUrl(url)) {
                                await launchUrl(
                                  url,
                                  mode: LaunchMode.externalApplication,
                                );
                              } else {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Could not launch URL'),
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    if (pulling &&
                        selectedModel != null &&
                        !remoteCatalog.contains(selectedModel))
                      Padding(
                        padding: const EdgeInsets.only(top: 12.0),
                        child: Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: pullProgress > 0 ? pullProgress : null,
                              ),
                            ),
                            if (pullStatusText != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                pullStatusText!,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      )
                    else if (pulling && hasLocalModels)
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: pullProgress > 0 ? pullProgress : null,
                            ),
                          ),
                          if (pullStatusText != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              pullStatusText!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCloudModelsTab() {
    final localizations = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isLoadingCloudModels)
              const Center(child: CircularProgressIndicator())
            else if (cloudModelsError != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                        size: 48,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        cloudModelsError!,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _fetchCloudModels,
                        child: Text(localizations.retry),
                      ),
                    ],
                  ),
                ),
              )
            else if (cloudModels.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        Icons.cloud_off,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        size: 48,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        localizations.noModelsAvailable,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        localizations.checkConnectionOrSettings,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: cloudModels.length,
                  itemBuilder: (_, i) {
                    final model = cloudModels[i];
                    final selected = model == selectedModel;
                    return Card(
                      color: selected ? Colors.blue[50] : null,
                      child: ListTile(
                        title: Text(model),
                        trailing: selected
                            ? const Icon(
                                Icons.check_circle,
                                color: Colors.blue,
                              )
                            : null,
                        selected: selected,
                        onTap: () {
                          setState(() => selectedModel = model);
                          _tabController!.animateTo(2);
                          _saveSettings();
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudSettingsTab() {
    final localizations = AppLocalizations.of(context)!;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localizations.cloudSettings,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      decoration: InputDecoration(
                        labelText: localizations.baseUrl,
                        hintText: 'https://api.example.com',
                        border: const OutlineInputBorder(),
                      ),
                      controller: TextEditingController(text: cloudBaseUrl),
                      onChanged: (value) {
                        cloudBaseUrl = value.trim();
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      decoration: InputDecoration(
                        labelText: localizations.apiKey,
                        hintText: 'sk-...',
                        border: const OutlineInputBorder(),
                      ),
                      obscureText: true,
                      controller: TextEditingController(text: cloudApiKey),
                      onChanged: (value) {
                        cloudApiKey = value.trim();
                      },
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _testCloudConnection,
                            child: Text(localizations.testConnection),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _saveCloudSettings,
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.primary,
                            ),
                            child: Text(localizations.saveSettings),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (isLoadingCloudModels)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatTab() {
    final modelSelected = selectedModel != null;
    final localizations = AppLocalizations.of(context)!;
    return SafeArea(
      child: Column(
        children: [
          if (!modelSelected)
            Expanded(
              child: Center(
                child: Text(
                  currentProvider == AIProvider.local
                      ? localizations.selectOrDownloadModel
                      : localizations.selectModel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: messages.length,
                itemBuilder: (_, i) {
                  final m = messages[i];
                  final isLastAssistant =
                      i == messages.length - 1 &&
                      !m.fromUser &&
                      chatInputEnabled;
                  final brightness = Theme.of(context).brightness;
                  return Align(
                    alignment: m.fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: m.fromUser
                            ? brightness == Brightness.dark
                                ? Colors.blue[900]
                                : Colors.blue[200]
                            : brightness == Brightness.dark
                                ? Colors.grey[800]
                                : Colors.grey[200],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: m.fromUser
                          ? Text(m.text)
                          : (isLastAssistant
                              ? SelectionArea(
                                  child: GptMarkdown(
                                    m.text,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                )
                              : SelectableText(m.text)),
                    ),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    enabled: modelSelected && chatInputEnabled,
                    decoration: InputDecoration(
                      hintText: modelSelected
                          ? localizations.typeMessage
                          : localizations.selectAModel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    minLines: 1,
                    maxLines: 4,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                if (!chatInputEnabled)
                  ElevatedButton(
                    onPressed: () {
                      _chatStreamSub?.cancel();
                      _cloudChatStreamSub?.cancel();
                      setState(() => chatInputEnabled = true);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(12),
                    ),
                    child: const Icon(Icons.stop),
                  )
                else
                  ElevatedButton(
                    onPressed: modelSelected && chatInputEnabled
                        ? _sendMessage
                        : null,
                    style: ElevatedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(12),
                    ),
                    child: const Icon(Icons.send),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool fromUser;
  ChatMessage({required this.text, this.fromUser = false});
  ChatMessage copyWith({String? text, bool? fromUser}) =>
      ChatMessage(text: text ?? this.text, fromUser: fromUser ?? this.fromUser);
}
