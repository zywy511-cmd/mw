import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/third_party/manwaba_auth.dart';
import '../models/user_manager.dart';
import '../theme/app_spacing.dart';
import '../utils/toast.dart';

/// 漫屋吧账号登录 / 注册页。
///
/// 对接 manwabb.cc 账号系统：登录后收藏与浏览记录均与账号同步。
class ManwabaLoginPage extends StatefulWidget {
  const ManwabaLoginPage({super.key});

  @override
  State<ManwabaLoginPage> createState() => _ManwabaLoginPageState();
}

class _ManwabaLoginPageState extends State<ManwabaLoginPage> {
  final _user = UserManager();
  final _formKey = GlobalKey<FormState>();

  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  bool _isRegister = false;
  bool _busy = false;
  bool _obscure = true;

  Uint8List? _captchaBytes;
  String _captchaId = '';

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _emailCtrl.dispose();
    _nicknameCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCaptcha() async {
    try {
      final result = await ManwabaAuth.instance.fetchCaptcha();
      if (!mounted) return;
      setState(() {
        _captchaBytes = result.bytes;
        _captchaId = result.captchaId;
      });
    } catch (_) {
      // 验证码加载失败不阻塞登录。
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      late final ManwabaLoginResult result;
      if (_isRegister) {
        result = await ManwabaAuth.instance.register(
          username: _usernameCtrl.text.trim(),
          password: _passwordCtrl.text,
          email: _emailCtrl.text.trim(),
          nickname: _nicknameCtrl.text.trim(),
          captchaId: _captchaId,
          captchaCode: _captchaCtrl.text.trim(),
        );
      } else {
        result = await ManwabaAuth.instance.login(
          _usernameCtrl.text.trim(),
          _passwordCtrl.text,
        );
      }
      await _user.setManwabaAuth(
        token: result.token,
        userId: result.userId,
        username: result.username,
        nickname: result.nickname,
      );
      if (!mounted) return;
      showToast(context, _isRegister ? '注册成功' : '登录成功');
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, '$e', isError: true);
      if (_isRegister) unawaited(_refreshCaptcha());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isRegister ? '注册漫屋吧账号' : '登录漫屋吧账号'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.md),
              Text(
                '漫屋吧',
                style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '登录后同步你的收藏与浏览记录',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              TextFormField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '密码',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _busy ? null : _submit(),
                validator: (v) =>
                    (v == null || v.isEmpty) ? '请输入密码' : null,
              ),
              if (_isRegister) ...[
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _nicknameCtrl,
                  decoration: const InputDecoration(
                    labelText: '昵称（可选）',
                    prefixIcon: Icon(Icons.badge),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '邮箱（可选）',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    if (_captchaBytes != null)
                      GestureDetector(
                        onTap: _refreshCaptcha,
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            border: Border.all(color: cs.outlineVariant),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Image.memory(_captchaBytes!,
                              fit: BoxFit.fitHeight),
                        ),
                      )
                    else
                      const SizedBox(height: 48, width: 120),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextFormField(
                        controller: _captchaCtrl,
                        decoration: const InputDecoration(
                          labelText: '图形验证码',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => _isRegister &&
                                (v == null || v.trim().isEmpty)
                            ? '请输入验证码'
                            : null,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    IconButton(
                      onPressed: _refreshCaptcha,
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新验证码',
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isRegister ? '注册' : '登录'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        setState(() => _isRegister = !_isRegister);
                        if (_isRegister) unawaited(_refreshCaptcha());
                      },
                child: Text(_isRegister ? '已有账号？去登录' : '没有账号？去注册'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
