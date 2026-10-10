// SPDX-License-Identifier: Apache-2.0
import '../../core/util/url_utils.dart';

/// Çevrimdışı, "en iyi çaba" 2FA/TOTP destekleyen alan adları listesi (statik).
/// Eksiksiz DEĞİLDİR; [withExtra] ile genişletilebilir. İnternet sorgusu yapılmaz.
class TwoFactorDirectory {
  const TwoFactorDirectory([this._extra = const {}]);
  final Set<String> _extra;

  TwoFactorDirectory withExtra(Iterable<String> domains) =>
      TwoFactorDirectory({..._extra, ...domains.map((d) => d.toLowerCase())});

  static const Set<String> builtin = {
    'google.com', 'github.com', 'gitlab.com', 'bitbucket.org', 'microsoft.com',
    'live.com', 'outlook.com', 'office.com', 'azure.com', 'apple.com',
    'icloud.com', 'amazon.com', 'facebook.com', 'instagram.com', 'twitter.com',
    'x.com', 'linkedin.com', 'reddit.com', 'dropbox.com', 'slack.com',
    'discord.com', 'paypal.com', 'stripe.com', 'binance.com', 'coinbase.com',
    'kraken.com', 'cloudflare.com', 'digitalocean.com', 'heroku.com',
    'netlify.com', 'vercel.com', 'npmjs.com', 'pypi.org', 'docker.com',
    'atlassian.com', 'trello.com', 'notion.so', 'zoom.us', 'twitch.tv',
    'steampowered.com', 'epicgames.com', 'ea.com', 'ubisoft.com',
    'playstation.com', 'nintendo.com', 'proton.me', 'protonmail.com',
    'tutanota.com', 'fastmail.com', 'yahoo.com', 'mailchimp.com', 'shopify.com',
    'godaddy.com', 'namecheap.com', 'ovh.com', 'hetzner.com', 'linode.com',
    'backblaze.com', 'wise.com', 'revolut.com', 'robinhood.com', 'gemini.com',
    'bitstamp.com', 'kucoin.com', 'okx.com', 'bybit.com', 'telegram.org',
    'whatsapp.com', 'signal.org', 'snapchat.com', 'tiktok.com', 'pinterest.com',
    'medium.com', 'wordpress.com', 'ebay.com', 'etsy.com', 'airbnb.com',
    'uber.com', 'booking.com', 'spotify.com', 'lastpass.com', '1password.com',
    'bitwarden.com', 'okta.com', 'auth0.com', 'twilio.com', 'sentry.io',
    'datadog.com', 'mongodb.com', 'turkiye.gov.tr',
  };

  /// [url] bir alan adı (veya alt alan adı) eşleşiyorsa true.
  bool supports(String url) {
    final h = hostOf(url);
    if (h == null) return false;
    bool match(String d) => h == d || h.endsWith('.$d');
    return builtin.any(match) || _extra.any(match);
  }
}
