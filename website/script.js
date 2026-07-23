const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealElements = document.querySelectorAll(".reveal");
const copyCommandButton = document.querySelector(".copy-command");

if (!reducedMotion && "IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { rootMargin: "0px 0px -8%", threshold: 0.08 },
  );

  revealElements.forEach((element) => observer.observe(element));
}

if (copyCommandButton) {
  const copyLabel = copyCommandButton.querySelector("span");
  let resetLabelTimer;

  copyCommandButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(copyCommandButton.dataset.copy);
      copyLabel.textContent = "복사됨";
      clearTimeout(resetLabelTimer);
      resetLabelTimer = setTimeout(() => {
        copyLabel.textContent = "복사";
      }, 1800);
    } catch {
      copyLabel.textContent = "직접 복사";
    }
  });
}
