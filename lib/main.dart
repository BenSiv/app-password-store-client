import 'package:app/src/app/app.dart';
import 'package:app/src/data/git2.dart';
import 'package:app/src/data/repository.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeLibgit2();
  await Repository.instance.initialize();
  runApp(App());
}
