export type ThemeChoice = "system" | "light" | "dark";

/** 设置文件可能被改坏或来自旧版本，认不出的值一律当作跟随系统。 */
export function normalizeTheme(value: unknown): ThemeChoice {
  return value === "light" || value === "dark" ? value : "system";
}

export function resolveTheme(choice: ThemeChoice, systemDark: boolean): "light" | "dark" {
  if (choice === "system") return systemDark ? "dark" : "light";
  return choice;
}
