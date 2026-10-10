// SPDX-License-Identifier: Apache-2.0
/// Hata türleri kasıtlı olarak kaba: yanlış parola ile yanlış Secret Key
/// birbirinden ayırt EDİLEMEZ (ikisi de [authenticationFailed]).
enum CryptoFailure {
  authenticationFailed,
  headerTampered,
  malformedData,
  unsupportedVersion,
  weakParameters,
  invalidInput,
  recoveryInvalid,
}

/// Mesaj taşımaz; hiçbir hassas veri exception'a girmez.
class QuantaCryptoException implements Exception {
  const QuantaCryptoException(this.kind);
  final CryptoFailure kind;

  @override
  String toString() => 'QuantaCryptoException(${kind.name})';
}
