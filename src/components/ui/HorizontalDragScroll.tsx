import { useEffect } from "react";

const interactiveSelector = "button,a,input,select,textarea,[role='button'],[role='dialog']";

export function HorizontalDragScroll() {
  useEffect(() => {
    let area: HTMLElement | null = null;
    let startX = 0;
    let startScrollLeft = 0;
    let dragged = false;

    const findArea = (target: EventTarget | null) => {
      const element = target instanceof Element ? target : null;
      const candidate = element?.closest<HTMLElement>(".overflow-x-auto");
      if (!candidate || candidate.classList.contains("cursor-grab")) return null;
      return candidate.scrollWidth > candidate.clientWidth ? candidate : null;
    };

    const down = (event: PointerEvent) => {
      if (event.pointerType !== "mouse" || event.button !== 0) return;
      if (event.target instanceof Element && event.target.closest(interactiveSelector)) return;
      area = findArea(event.target);
      if (!area) return;
      startX = event.clientX;
      startScrollLeft = area.scrollLeft;
      dragged = false;
      area.style.cursor = "grabbing";
      area.style.userSelect = "none";
      area.setPointerCapture?.(event.pointerId);
    };

    const move = (event: PointerEvent) => {
      if (!area) return;
      const distance = event.clientX - startX;
      if (Math.abs(distance) > 3) dragged = true;
      if (!dragged) return;
      event.preventDefault();
      area.scrollLeft = startScrollLeft - distance;
    };

    const end = () => {
      if (!area) return;
      area.style.cursor = "grab";
      area.style.userSelect = "";
      area = null;
    };

    const showHand = () => {
      document.querySelectorAll<HTMLElement>(".overflow-x-auto").forEach((element) => {
        if (
          !element.classList.contains("cursor-grab") &&
          element.scrollWidth > element.clientWidth
        ) {
          element.style.cursor = "grab";
        }
      });
    };
    showHand();
    const observer = new MutationObserver(() => window.requestAnimationFrame(showHand));
    observer.observe(document.body, { childList: true, subtree: true });
    window.addEventListener("resize", showHand);
    document.addEventListener("pointerdown", down);
    document.addEventListener("pointermove", move, { passive: false });
    document.addEventListener("pointerup", end);
    document.addEventListener("pointercancel", end);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", showHand);
      document.removeEventListener("pointerdown", down);
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", end);
      document.removeEventListener("pointercancel", end);
    };
  }, []);

  return null;
}
