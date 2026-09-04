import 'package:dash/extensions/responsive_border_radius.dart';
import 'package:dash/extensions/responsive_spacing.dart';
import 'package:dash/screens/public_profile_page.dart';
import 'package:dash/utils/profile_link.dart';
import 'package:dash/widgets/dash_navigation_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:permission_handler/permission_handler.dart';

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  MobileScannerController? _controller;
  bool _hasScanned = false;
  bool _isCheckingPermission = true;

  @override
  void initState() {
    super.initState();
    _checkPermissionAndStart();
  }

  @override
  void dispose() {
    try {
      _controller?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData contextTheme = Theme.of(context);

    final double scannerDim = ( MediaQuery.widthOf(context) < MediaQuery.heightOf(context) )
      ? MediaQuery.widthOf(context) * 2 / 3
      : MediaQuery.heightOf(context) * 2 / 3;

    return Scaffold(
      backgroundColor: contextTheme.scaffoldBackgroundColor,
      appBar: DashNavigationTopBar(
        title: "Scan QR Code",
        actions: [
          if (_controller != null)
            IconButton(
              icon: const Icon(Symbols.flashlight_on_rounded),
              onPressed: () => _controller?.toggleTorch(),
            ),
        ],
      ),
      body: _isCheckingPermission || _controller == null
        ? const Center(child: CircularProgressIndicator())
        : Stack(
          children: [
            MobileScanner(
              controller: _controller!,
              onDetect: _handleDetect,
              errorBuilder: (context, error) {
                return Center(
                  child: Text(
                    'Camera error\n Give access to camera from settings',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                );
              },
            ),
            Center(
              child: Container(
                width: scannerDim,
                height: scannerDim,
                decoration: BoxDecoration(
                  border: Border.all(color: contextTheme.colorScheme.tertiary, width: ResponsiveSpacing().xs),
                  borderRadius: context.radiusMd,
                ),
              ),
            ),
          ],
        ),
    );
  }

  Future<void> _checkPermissionAndStart() async {
    try {
      var status = await Permission.camera.status;

      if (!status.isGranted) {
        status = await Permission.camera.request();
      }

      if (!status.isGranted) {
        if (mounted) Navigator.pop(context);
        return;
      }

      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );

      try {
        await _controller!.start();
      } catch (e) {
        debugPrint("Error starting mobile scanner controller: $e");
      }
    } catch (e) {
      debugPrint("Permission check error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingPermission = false;
        });
      }
    }
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    final List<Barcode> barcodes = capture.barcodes;

    for (final barcode in barcodes) {
      final String? scannedUserId = ProfileLink.userIdFrom(barcode.rawValue);
      if (scannedUserId == null) continue;

      setState(() {
        _hasScanned = true;
      });

      _controller?.stop();

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => PublicProfilePage(userId: scannedUserId),
        ),
      );
      return;
    }
  }
}