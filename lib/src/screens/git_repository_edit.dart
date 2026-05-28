import 'package:app/src/data/models.dart';
import 'package:app/src/data/repository.dart';
import 'package:app/src/utils/form_field_validators.dart';
import 'package:app/src/utils/logger.dart';
import 'package:app/src/utils/show_error_dialog.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final class GitRepositoryEditScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Repository.instance.subscribeGitRepositoryMetadata().first,
      builder: (context, ss) {
        if (ss.error == 'Git repository not found') return _GitRepositoryEditScreen(null);
        if (ss.hasError) return Material(child: Center(child: Text('${ss.error}')));
        if (ss.connectionState == ConnectionState.waiting) return SizedBox();
        return _GitRepositoryEditScreen(ss.data);
      },
    );
  }
}

final class _GitRepositoryEditScreen extends StatefulWidget {
  const _GitRepositoryEditScreen(this.metadata);

  final GitRepositoryMetadata? metadata;

  @override
  State<StatefulWidget> createState() {
    return _GitRepositoryEditScreenState();
  }
}

final class _GitRepositoryEditScreenState extends State<_GitRepositoryEditScreen> {
  final _formKey = GlobalKey<FormState>();
  var _autovalidateMode = AutovalidateMode.disabled;
  var _credentialType = 0;
  final _urlController = TextEditingController();
  final _branchController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  var _passwordVisibility = false;

  @override
  void initState() {
    super.initState();
    final metadata = widget.metadata;
    if (metadata == null) return;
    _urlController.text = metadata.url;
    _branchController.text = metadata.branch;
    final credential = metadata.credential;
    switch (credential) {
      case GitCredentialUserPass():
        _credentialType = 1;
        _usernameController.text = credential.username;
        _passwordController.text = credential.password;
      case null:
        _credentialType = 0;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _branchController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSyncAndSave() async {
    if (_autovalidateMode != AutovalidateMode.onUserInteraction) {
      setState(() => _autovalidateMode = AutovalidateMode.onUserInteraction);
    }
    if (!_formKey.currentState!.validate()) {
      logger.info('Form invalid');
      return;
    }
    try {
      await Repository.instance.syncAndSaveGitRepository(
        url: _urlController.text,
        branch: _branchController.text,
        credential: _credentialType == 0 ? null : GitCredentialUserPass((b) => b
          ..username = _usernameController.text
          ..password = _passwordController.text,
        ),
      );
    } catch (e) {
      showErrorDialog(context, '$e');
      return;
    }
    // NOTE: avoid "Unhandled Exception: Bad state: Cannot add event after closing"
    await Future.delayed(Duration(milliseconds: 100));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Git repository synced and saved successfully')),
    );
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Git Repository'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: _autovalidateMode,
          child: ListView(
            padding: EdgeInsets.all(32),
            children: [
              TextFormField(
                keyboardType: TextInputType.url,
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Repository URL',
                  helperText: '',
                ),
                validator: FormFieldValidators.isRequired,
              ),
              SizedBox(height: 20),
              TextFormField(
                keyboardType: TextInputType.text,
                controller: _branchController,
                decoration: InputDecoration(
                  labelText: 'Branch Name',
                  helperText: '',
                ),
              ),
              SizedBox(height: 20),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Credential',
                  helperText: '',
                ),
                child: Row(
                  children: ['None', 'Password'].asMap().entries.map((e) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Radio<int>(
                        value: e.key,
                        groupValue: _credentialType,
                        onChanged: (value) => setState(() => _credentialType = value!),
                        visualDensity: VisualDensity.compact,
                      ),
                      Text(e.value),
                      SizedBox(width: 16),
                    ],
                  )).toList(),
                ),
              ),
              if (_credentialType == 1) ...[
                SizedBox(height: 20),
                TextFormField(
                  keyboardType: TextInputType.text,
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    helperText: '',
                  ),
                  validator: FormFieldValidators.isRequired,
                ),
                SizedBox(height: 20),
                TextFormField(
                  obscureText: !_passwordVisibility,
                  keyboardType: TextInputType.visiblePassword,
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: '',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _passwordVisibility = !_passwordVisibility),
                      icon: Icon(_passwordVisibility ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                  validator: FormFieldValidators.isRequired,
                ),
              ],
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => _handleSyncAndSave(),
                child: Text('Sync and Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
