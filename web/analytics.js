// First-party page-view beacon for the SimCrux web app (app.simcrux.app).
//
// The same beacon the marketing sites carry, and only that: one page view per
// application load, posted to our own endpoint, which writes one row to the
// crux_web Analytics Engine dataset under the `simcrux-app` site slug. It is
// what answers "how many people open the web edition" in the suite's own
// traffic reporting, beside the marketing sites' figures.
//
// WHAT THIS SENDS: the site slug, the path (never the query string, never the
// fragment) and the referring HOST (never the referring URL). Everything else
// on the row — country, network, the coarse browser and OS class — is derived
// by the edge from request metadata.
//
// WHAT THIS STORES ON THE VISITOR'S DEVICE: nothing. No cookie, no
// localStorage, no sessionStorage, no visitor id, and that is a hard
// constraint, not a default. The application's own telemetry is a separate
// in-app path with its own consent flow and its own storage; this beacon
// neither reads nor writes any of it.
//
// Global Privacy Control and Do Not Track both switch it off entirely.
(function () {
  'use strict';

  var SITE = 'simcrux-app';
  var ENDPOINT = 'https://telemetry.edacrux.app/v1/pageview';

  if (navigator.globalPrivacyControl === true) return;
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1') return;

  try {
    // `pathname` only: `location.search` and `location.hash` are dropped at
    // the source rather than trusted to be stripped later.
    var path = location.pathname || '/';

    // The referring HOST, never the URL. A same-site referrer is reported as
    // none, so in-app navigation does not drown out the inbound sources.
    var referer = '';
    if (document.referrer) {
      try {
        var host = new URL(document.referrer).hostname;
        if (host && host !== location.hostname) referer = host;
      } catch (e) {
        /* an unparseable referrer is simply no referrer */
      }
    }

    var body = JSON.stringify({ site: SITE, path: path, referer_host: referer });

    // text/plain, deliberately: `application/json` is not CORS-safelisted, so
    // the browser would preflight, and `sendBeacon` cannot report a preflight
    // that fails. The endpoint parses the body regardless of the header.
    var blob = new Blob([body], { type: 'text/plain;charset=UTF-8' });

    if (navigator.sendBeacon && navigator.sendBeacon(ENDPOINT, blob)) return;

    if (window.fetch) {
      fetch(ENDPOINT, {
        method: 'POST',
        body: body,
        keepalive: true,
        mode: 'no-cors',
      }).catch(function () {});
    }
  } catch (e) {
    // A page view is never worth an error in the application.
  }
})();
