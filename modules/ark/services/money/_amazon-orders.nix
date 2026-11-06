# amazon-orders (github.com/alexdlaird/amazon-orders), the program money's
# importer runs at each sync for Amazon's orders and how each was charged
# (services.money.amazon.package), signed in by the login given in the
# app's Settings. Not in nixpkgs, so built here from PyPI; its own tests
# talk to Amazon, so only the import is checked.
#
# With its [browser] extra (Playwright): Amazon answers a sign-in from a
# new place with a JavaScript challenge, which only a browser can run.
# Patched to use a browser that is already running, over DevTools, when
# AMAZON_ORDERS_CDP names one (money-server passes sivrad's, ../sivrad):
# the challenge runs in a context of its own there, and one that wants a
# person opens on that browser's screen, which its page shows, rather than
# on a display this server does not have.
{ python3Packages, fetchPypi }:
python3Packages.buildPythonApplication rec {
  pname = "amazon-orders";
  version = "5.2.1";
  pyproject = true;

  src = fetchPypi {
    pname = "amazon_orders";
    inherit version;
    hash = "sha256-eMy2NJilbfjlxC1jCp000iKKudMYb7bP2ujo8GHt/js=";
  };

  postPatch = ''
    substituteInPlace amazonorders/contrib/browser/playwright.py \
      --replace-fail '        browser_name = self.config.browser
    ' '        cdp = os.environ.get("AMAZON_ORDERS_CDP")
            if cdp:
                return pw.chromium.connect_over_cdp(cdp)
            browser_name = self.config.browser
    '
    substituteInPlace amazonorders/util.py \
      --replace-fail '    return not sys.platform.startswith("linux") or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))' \
        '    return bool(os.environ.get("AMAZON_ORDERS_CDP")) or not sys.platform.startswith("linux") or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))'
  '';

  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [
    beautifulsoup4
    click
    pillow
    playwright
    pyotp
    python-dateutil
    pyyaml
    requests
  ];

  # The browser's sign-in steps, which amazon-orders leaves out unless told:
  # Amazon's ACIC check and its JavaScript challenge page, run in the
  # browser, and a puzzle opened on the browser's screen for a person to
  # solve (on its page). No third-party captcha solver.
  makeWrapperArgs = [
    "--set-default AMAZON_AUTH_FORMS_CLASSES '[amazonorders.contrib.browser.playwright.PlaywrightAcicForm, amazonorders.contrib.browser.playwright.PlaywrightJSAuthForm, amazonorders.contrib.browser.playwright.PlaywrightManualWafForm]'"
  ];

  doCheck = false;
  pythonImportsCheck = [
    "amazonorders"
    "amazonorders.contrib.browser.playwright"
  ];

  meta.mainProgram = "amazon-orders";
}
