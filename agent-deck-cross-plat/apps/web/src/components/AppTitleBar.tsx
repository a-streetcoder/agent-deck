import { hasIntegratedDesktopChrome, openAppMenu } from "@/lib/native";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import type { MouseEvent } from "react";

const MENUS = ["file", "edit", "view", "help"] as const;

function openAnchoredMenu(
  event: MouseEvent<HTMLButtonElement>,
  name: (typeof MENUS)[number],
): void {
  const buttonBounds = event.currentTarget.getBoundingClientRect();
  const titlebarBounds = event.currentTarget.closest("header")?.getBoundingClientRect();
  void openAppMenu(name, {
    x: Math.round(buttonBounds.left),
    y: Math.round(titlebarBounds?.bottom ?? buttonBounds.bottom),
  });
}

interface AppTitleBarProps {
  sidebarVisible: boolean;
  onToggleSidebar: () => void;
}

/** Windows/Linux title bar: window navigation and native application menus. */
export function AppTitleBar({ sidebarVisible, onToggleSidebar }: AppTitleBarProps) {
  if (!hasIntegratedDesktopChrome()) return null;

  return (
    <header
      className="desktop-titlebar"
      data-testid="desktop-titlebar"
      aria-label="Application title bar"
    >
      <button
        className="desktop-sidebar-toggle"
        type="button"
        data-testid="desktop-sidebar-toggle"
        aria-label={sidebarVisible ? "Hide sidebar" : "Show sidebar"}
        title={sidebarVisible ? "Hide sidebar" : "Show sidebar"}
        onClick={onToggleSidebar}
      >
        {sidebarVisible ? <PanelLeftClose size={16} /> : <PanelLeftOpen size={16} />}
      </button>
      <nav className="desktop-titlebar-menu" aria-label="Application menu">
        {MENUS.map((name) => (
          <button
            key={name}
            type="button"
            data-testid={`desktop-menu-${name}`}
            onClick={(event) => openAnchoredMenu(event, name)}
          >
            {name[0]!.toUpperCase() + name.slice(1)}
          </button>
        ))}
      </nav>
    </header>
  );
}
