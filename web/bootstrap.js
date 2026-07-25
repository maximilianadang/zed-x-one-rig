(function () {
  "use strict";

  var connection = document.getElementById("connection-pill");
  var controller = document.getElementById("controller-pill");
  var message = document.getElementById("operator-message");

  if (connection) connection.textContent = "APP LOADING";
  if (controller) controller.textContent = "CONTROL STARTING";

  function describe(value) {
    if (!value) return "unknown browser error";
    if (typeof value === "string") return value;
    return value.message || String(value);
  }

  function showFailure(value) {
    var detail = describe(value);
    if (connection) {
      connection.textContent = "BROWSER ERROR";
      connection.className = "pill danger";
    }
    if (controller) {
      controller.textContent = "NOT STARTED";
      controller.className = "pill danger";
    }
    if (message) {
      message.textContent =
        "Browser application failed before connecting: " + detail +
        "\nTry the same URL in current Chrome, Firefox, or Safari and reload.";
      message.style.color = "var(--red)";
    }
  }

  window.__zedShowBootFailure = showFailure;
  window.addEventListener("error", function (event) {
    showFailure(event.error || event.message);
  });
  window.addEventListener("unhandledrejection", function (event) {
    showFailure(event.reason);
  });
  window.setTimeout(function () {
    if (!window.__zedAppStarted) {
      showFailure("app.js did not start (module load, syntax, or browser compatibility failure)");
    }
  }, 5000);
}());
