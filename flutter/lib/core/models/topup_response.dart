/// TopupResponse — invoice response returned after initiating topup.
/// Matches Go: api.topupResponse
class TopupResponse {
  final int invoiceId;
  final String payUrl;
  final String amount;
  final String asset;

  TopupResponse({
    this.invoiceId = 0,
    this.payUrl = '',
    this.amount = '',
    this.asset = '',
  });

  factory TopupResponse.fromJson(Map<String, dynamic> j) {
    final rawInvoiceId = j['invoice_id'];
    final invoiceId = rawInvoiceId is num
        ? rawInvoiceId.toInt()
        : (rawInvoiceId != null ? int.tryParse(rawInvoiceId.toString()) ?? 0 : 0);

    return TopupResponse(
      invoiceId: invoiceId,
      payUrl: (j['pay_url'] ?? '').toString(),
      amount: (j['amount'] ?? '').toString(),
      asset: (j['asset'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'invoice_id': invoiceId,
        'pay_url': payUrl,
        'amount': amount,
        'asset': asset,
      };
}

/// TopupStatusResponse — status response for checking invoice payment status.
/// Returned by GET /v1/billing/topup/{id}
class TopupStatusResponse {
  final int invoiceId;
  final String status;

  TopupStatusResponse({
    this.invoiceId = 0,
    this.status = '',
  });

  factory TopupStatusResponse.fromJson(Map<String, dynamic> j) {
    final rawInvoiceId = j['invoice_id'];
    final invoiceId = rawInvoiceId is num
        ? rawInvoiceId.toInt()
        : (rawInvoiceId != null ? int.tryParse(rawInvoiceId.toString()) ?? 0 : 0);

    return TopupStatusResponse(
      invoiceId: invoiceId,
      status: (j['status'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'invoice_id': invoiceId,
        'status': status,
      };
}
