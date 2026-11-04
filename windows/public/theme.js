// 在页面显示之前定好深浅色，避免打开时先闪一下另一种配色。之后由 src/app/theme.ts 接管。
(function () {
  var choice = "system";
  try {
    choice = JSON.parse(localStorage.getItem("baud.settings")).theme;
  } catch (e) {}
  var dark = choice === "dark" || (choice !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
})();
