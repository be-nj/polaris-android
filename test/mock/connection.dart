import 'package:polaris/core/connection.dart';

class ConnectionManager implements ManagerInterface {
  final String? host;
  final bool connected;

  ConnectionManager(this.host, {this.connected = true});

  @override
  String? get url => host;

  @override
  int? get apiVersion => 8;

  @override
  bool isConnected() => connected;
}
