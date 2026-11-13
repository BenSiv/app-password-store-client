import 'package:app/src/data/repository.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final class VaultListScreen extends StatefulWidget {
  @override
  State<StatefulWidget> createState() {
    return _VaultListScreenState();
  }
}

final class _VaultListScreenState extends State<VaultListScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Vaults'),
        actions: [
          ListenableBuilder(
            listenable: Repository.instance.lockStateListenable,
            builder: (context, _) {
              if (!Repository.instance.isAppLockEnabled) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: 'Lock Vault',
                icon: const Icon(Icons.lock_outline),
                onPressed: Repository.instance.lock,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<Iterable<String>>(
          stream: Repository.instance.subscribeVaultList(),
          builder: (context, ss) {
            if (ss.hasError) return Center(child: Text('${ss.error}'));
            final vaultList = ss.data;
            if (vaultList == null) return SizedBox();
            if (vaultList.isEmpty) return Center(child: Text('No vaults'));
            return ListView(
              children: vaultList.map((e) => ListTile(
                title: Text(e),
                onTap: () => context.go('/vaults/$e'),
              )).toList(),
            );
          },
        ),
      ),
    );
  }
}
