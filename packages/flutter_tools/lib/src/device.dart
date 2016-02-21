// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'android/android_device.dart';
import 'application_package.dart';
import 'base/common.dart';
import 'base/utils.dart';
import 'build_configuration.dart';
import 'globals.dart';
import 'ios/devices.dart';
import 'ios/simulators.dart';
import 'toolchain.dart';

/// A class to get all available devices.
class DeviceManager {
  /// Constructing DeviceManagers is cheap; they only do expensive work if some
  /// of their methods are invoked.
  DeviceManager() {
    // Register the known discoverers.
    _deviceDiscoverers.add(new AndroidDevices());
    _deviceDiscoverers.add(new IOSDevices());
    _deviceDiscoverers.add(new IOSSimulators());
  }

  List<DeviceDiscovery> _deviceDiscoverers = <DeviceDiscovery>[];

  /// A user-specified device ID.
  String specifiedDeviceId;

  bool get hasSpecifiedDeviceId => specifiedDeviceId != null;

  /// Return the device with the matching ID; else, complete the Future with
  /// `null`.
  ///
  /// This does a case insentitive compare with `deviceId`.
  Future<Device> getDeviceById(String deviceId) async {
    deviceId = deviceId.toLowerCase();
    List<Device> devices = await getAllConnectedDevices();
    return devices.firstWhere(
      (Device device) => device.id.toLowerCase() == deviceId,
      orElse: () => null
    );
  }

  /// Return the list of connected devices, filtered by any user-specified device id.
  Future<List<Device>> getDevices() async {
    if (specifiedDeviceId == null) {
      return getAllConnectedDevices();
    } else {
      Device device = await getDeviceById(specifiedDeviceId);
      return device == null ? <Device>[] : <Device>[device];
    }
  }

  /// Return the list of all connected devices.
  Future<List<Device>> getAllConnectedDevices() async {
    return _deviceDiscoverers
      .where((DeviceDiscovery discoverer) => discoverer.supportsPlatform)
      .expand((DeviceDiscovery discoverer) => discoverer.devices)
      .toList();
  }
}

/// An abstract class to discover and enumerate a specific type of devices.
abstract class DeviceDiscovery {
  bool get supportsPlatform;
  List<Device> get devices;
}

/// A [DeviceDiscovery] implementation that uses polling to discover device adds
/// and removals.
abstract class PollingDeviceDiscovery extends DeviceDiscovery {
  PollingDeviceDiscovery(this.name);

  static const Duration _pollingDuration = const Duration(seconds: 4);

  final String name;
  ItemListNotifier<Device> _items;
  Timer _timer;

  List<Device> pollingGetDevices();

  void startPolling() {
    if (_timer == null) {
      if (_items == null)
        _items = new ItemListNotifier<Device>();
      _timer = new Timer.periodic(_pollingDuration, (Timer timer) {
        _items.updateWithNewList(pollingGetDevices());
      });
    }
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  List<Device> get devices {
    if (_items == null)
      _items = new ItemListNotifier<Device>.from(pollingGetDevices());
    return _items.items;
  }

  Stream<Device> get onAdded {
    if (_items == null)
      _items = new ItemListNotifier<Device>();
    return _items.onAdded;
  }

  Stream<Device> get onRemoved {
    if (_items == null)
      _items = new ItemListNotifier<Device>();
    return _items.onRemoved;
  }

  void dispose() => stopPolling();

  String toString() => '$name device discovery';
}

abstract class Device {
  Device(this.id);

  final String id;

  String get name;

  bool get supportsStartPaused => true;

  /// Install an app package on the current device
  bool installApp(ApplicationPackage app);

  /// Check if the device is currently connected
  bool isConnected();

  /// Check if the device is supported by Flutter
  bool isSupported();

  // String meant to be displayed to the user indicating if the device is
  // supported by Flutter, and, if not, why.
  String supportMessage() => isSupported() ? "Supported" : "Unsupported";

  /// Check if the current version of the given app is already installed
  bool isAppInstalled(ApplicationPackage app);

  TargetPlatform get platform;

  DeviceLogReader createLogReader();

  /// Start an app package on the current device.
  ///
  /// [platformArgs] allows callers to pass platform-specific arguments to the
  /// start call.
  Future<bool> startApp(
    ApplicationPackage package,
    Toolchain toolchain, {
    String mainPath,
    String route,
    bool checked: true,
    bool clearLogs: false,
    bool startPaused: false,
    int debugPort: observatoryDefaultPort,
    Map<String, dynamic> platformArgs
  });

  /// Stop an app package on the current device.
  Future<bool> stopApp(ApplicationPackage app);

  int get hashCode => id.hashCode;

  bool operator ==(dynamic other) {
    if (identical(this, other))
      return true;
    if (other is! Device)
      return false;
    return id == other.id;
  }

  String toString() => '$runtimeType $id';
}

/// Read the log for a particular device. Subclasses must implement `hashCode`
/// and `operator ==` so that log readers that read from the same location can be
/// de-duped. For example, two Android devices will both try and log using
/// `adb logcat`; we don't want to display two identical log streams.
abstract class DeviceLogReader {
  String get name;

  Future<int> logs({ bool clear: false });

  int get hashCode;
  bool operator ==(dynamic other);

  String toString() => name;
}

// TODO(devoncarew): Unify this with [DeviceManager].
class DeviceStore {
  DeviceStore({
    this.android,
    this.iOS,
    this.iOSSimulator
  });

  final AndroidDevice android;
  final IOSDevice iOS;
  final IOSSimulator iOSSimulator;

  List<Device> get all {
    List<Device> result = <Device>[];
    if (android != null)
      result.add(android);
    if (iOS != null)
      result.add(iOS);
    if (iOSSimulator != null)
      result.add(iOSSimulator);
    return result;
  }

  static Device _deviceForConfig(BuildConfiguration config, List<Device> devices) {
    Device device = null;

    if (config.deviceId != null) {
      // Step 1: If a device identifier is specified, try to find a device
      // matching that specific identifier
      device = devices.firstWhere(
          (Device dev) => (dev.id == config.deviceId),
          orElse: () => null);
    } else if (devices.length == 1) {
      // Step 2: If no identifier is specified and there is only one connected
      // device, pick that one.
      device = devices[0];
    } else if (devices.length > 1) {
      // Step 3: D:
      printStatus('Multiple devices are connected, but no device ID was specified.');
      printStatus('Attempting to launch on all connected devices.');
    }

    return device;
  }

  factory DeviceStore.forConfigs(List<BuildConfiguration> configs) {
    AndroidDevice android;
    IOSDevice iOS;
    IOSSimulator iOSSimulator;

    for (BuildConfiguration config in configs) {
      switch (config.targetPlatform) {
        case TargetPlatform.android:
          assert(android == null);
          android = _deviceForConfig(config, getAdbDevices());
          break;
        case TargetPlatform.iOS:
          assert(iOS == null);
          iOS = _deviceForConfig(config, IOSDevice.getAttachedDevices());
          break;
        case TargetPlatform.iOSSimulator:
          assert(iOSSimulator == null);
          iOSSimulator = _deviceForConfig(config, IOSSimulator.getAttachedDevices());
          break;
        case TargetPlatform.mac:
        case TargetPlatform.linux:
          break;
      }
    }

    return new DeviceStore(android: android, iOS: iOS, iOSSimulator: iOSSimulator);
  }
}
