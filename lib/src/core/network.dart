import 'package:connectivity_plus/connectivity_plus.dart';

Future<bool> isOnWifi() async {
  final result = await Connectivity().checkConnectivity();
  return result.contains(ConnectivityResult.wifi);
}

