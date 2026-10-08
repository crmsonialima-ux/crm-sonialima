import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

export type Theme = "dark" | "light";

export const THEME_STORAGE_KEY = "sonialima:theme";
export const THEME_COOKIE_KEY = "sonialima_theme";
export const THEME_CHANGE_EVENT = "sonialima:theme-change";

function userThemeStorageKey(userId?: string) {
  return userId ? `${THEME_STORAGE_KEY}:${userId}` : THEME_STORAGE_KEY;
}

function isTheme(value: string | null): value is Theme {
  return value === "dark" || value === "light";
}

function readThemeCookie(): Theme | null {
  if (typeof document === "undefined") return null;
  const saved = document.cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${THEME_COOKIE_KEY}=`))
    ?.split("=")[1];
  const normalizedSaved = saved ?? null;
  return isTheme(normalizedSaved) ? normalizedSaved : null;
}

export function readSavedTheme(userId?: string, preferredTheme?: Theme): Theme {
  if (typeof window === "undefined") return "dark";

  try {
    const saved = window.localStorage.getItem(userThemeStorageKey(userId));
    if (isTheme(saved)) return saved;
  } catch {
    // Cookies and the current root class remain available as fallbacks.
  }

  if (isTheme(preferredTheme ?? null)) return preferredTheme as Theme;
  const cookieTheme = readThemeCookie();
  if (cookieTheme) return cookieTheme;
  if (document.documentElement.classList.contains("light")) return "light";
  return "dark";
}

export function applyTheme(theme: Theme) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.classList.toggle("dark", theme === "dark");
  root.classList.toggle("light", theme === "light");
  root.dataset.theme = theme;
  root.style.colorScheme = theme;

  const themeColor = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
  themeColor?.setAttribute("content", theme === "light" ? "#f7f3ed" : "#171211");
}

function persistTheme(theme: Theme, userId?: string) {
  try {
    window.localStorage.setItem(userThemeStorageKey(userId), theme);
    if (userId) window.localStorage.setItem("sonialima:last-user-id", userId);
  } catch {
    // The long-lived cookie still persists the choice when storage is restricted.
  }
  document.cookie = `${THEME_COOKIE_KEY}=${theme}; path=/; max-age=31536000; SameSite=Lax`;
}

export function useTheme(userId?: string, preferredTheme?: Theme) {
  const [theme, setThemeState] = useState<Theme>(() => readSavedTheme(userId, preferredTheme));

  useEffect(() => {
    const synchronize = () => {
      const saved = readSavedTheme(userId, preferredTheme);
      setThemeState(saved);
      applyTheme(saved);
    };

    synchronize();
    window.addEventListener("storage", synchronize);
    window.addEventListener(THEME_CHANGE_EVENT, synchronize);
    return () => {
      window.removeEventListener("storage", synchronize);
      window.removeEventListener(THEME_CHANGE_EVENT, synchronize);
    };
  }, [preferredTheme, userId]);

  const setTheme = useCallback(
    (next: Theme) => {
      persistTheme(next, userId);
      applyTheme(next);
      setThemeState(next);
      window.dispatchEvent(new CustomEvent(THEME_CHANGE_EVENT, { detail: next }));
      if (userId) {
        void supabase.rpc("set_my_preferred_theme", { p_theme: next });
      }
    },
    [userId],
  );

  return { theme, setTheme };
}
