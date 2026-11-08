import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'store_catalog.dart';

enum PurchaseResult { granted, pending, cancelled, unavailable, error }

/// Real-money purchases.
///
/// * Android / iOS: Google Play Billing / StoreKit via `in_app_purchase`,
///   using each [Product.storeId] as the SKU.
/// * Windows / desktop: no store integration in this developer build.
/// * Debug "free purchases" bypasses the store entirely (no charge).
class PurchaseService {
  PurchaseService({required this.onGrant});

  /// Grants the purchased product to the player.
  final void Function(Product p) onGrant;

  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _details = {};
  final Map<String, Completer<PurchaseResult>> _pending = {};
  bool storeAvailable = false;

  bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    if (!_mobile) return;
    try {
      final iap = InAppPurchase.instance;
      storeAvailable = await iap.isAvailable();
      if (!storeAvailable) return;
      _sub = iap.purchaseStream.listen(_onPurchases, onError: (Object e) {
        debugPrint('purchase stream error: $e');
      });
      final resp = await iap.queryProductDetails({for (final p in kAllProducts) if (p.usd > 0) p.storeId});
      for (final d in resp.productDetails) {
        _details[d.id] = d;
      }
    } catch (e) {
      debugPrint('IAP init failed: $e');
      storeAvailable = false;
    }
  }

  /// Localised store price if the store returned one.
  String priceFor(Product p) => _details[p.storeId]?.price ?? p.priceLabel;

  Future<PurchaseResult> buy(Product p, {required bool debugFree}) async {
    if (debugFree || p.usd == 0) {
      onGrant(p);
      return PurchaseResult.granted;
    }
    final d = _details[p.storeId];
    if (!storeAvailable || d == null) return PurchaseResult.unavailable;
    final c = Completer<PurchaseResult>();
    _pending[p.storeId] = c;
    final param = PurchaseParam(productDetails: d);
    try {
      if (p.consumable) {
        await InAppPurchase.instance.buyConsumable(purchaseParam: param);
      } else {
        await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      }
    } catch (e) {
      _pending.remove(p.storeId);
      return PurchaseResult.error;
    }
    return c.future.timeout(const Duration(minutes: 5), onTimeout: () => PurchaseResult.pending);
  }

  Future<void> restore() async {
    if (storeAvailable) await InAppPurchase.instance.restorePurchases();
  }

  void _onPurchases(List<PurchaseDetails> list) async {
    for (final pd in list) {
      final product = kAllProducts.where((p) => p.storeId == pd.productID).firstOrNull;
      final waiter = _pending.remove(pd.productID);
      switch (pd.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // NOTE: production builds must verify pd.verificationData on a
          // server before granting.
          if (product != null) onGrant(product);
          waiter?.complete(PurchaseResult.granted);
        case PurchaseStatus.pending:
          if (waiter != null) _pending[pd.productID] = waiter;
        case PurchaseStatus.canceled:
          waiter?.complete(PurchaseResult.cancelled);
        case PurchaseStatus.error:
          waiter?.complete(PurchaseResult.error);
      }
      if (pd.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(pd);
      }
    }
  }

  void dispose() => _sub?.cancel();
}
