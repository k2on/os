# A headless browser for sivrad: Microsoft's Playwright MCP server (nixpkgs'
# playwright-mcp) with the Chromium builds that match its Playwright.
#   pkgs.callPackage ./_browser.nix { }
# nixpkgs points the server at every Playwright browser, twice: its wrapper
# sets PLAYWRIGHT_BROWSERS_PATH, and the playwright-test package it symlinks
# its node modules from carries the same path in its own wrapper. This swaps
# in Chromium alone in both places (the full build and the headless shell,
# which headless mode runs), keeping Firefox, WebKit and ffmpeg, and the
# libraries they drag in, out of the container's closure. How the server is
# started (headless, its profile, its output directory) is in the .mcp.json
# written by ./_guest.nix.
{
  playwright-mcp,
  playwright-driver,
  playwright-test,
}:
let
  every = playwright-driver.browsers;
  chromium = every.override {
    withFirefox = false;
    withWebkit = false;
    withFfmpeg = false;
  };
  # playwright-test's install script is a string that mentions the full set,
  # and a Nix string remembers every store path mentioned in it as a build
  # input (its context), so a plain replaceStrings would still build the
  # full set. Strip the context, swap the path, and put the context back
  # without the full set's derivation.
  test = playwright-test.overrideAttrs (old: {
    installPhase =
      builtins.appendContext
        (builtins.replaceStrings [ "${every}" ] [ "${chromium}" ] (
          builtins.unsafeDiscardStringContext old.installPhase
        ))
        (
          builtins.removeAttrs (builtins.getContext old.installPhase) [
            (builtins.unsafeDiscardStringContext every.drvPath)
          ]
        );
  });
in
playwright-mcp.override {
  playwright-driver = playwright-driver // {
    browsers = chromium;
  };
  playwright-test = test;
}
