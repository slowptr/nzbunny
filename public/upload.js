(() => {
  const zone = document.getElementById("dropZone");
  const input = document.getElementById("nzbfile");
  const list = document.getElementById("fileList");

  if (!zone || !input || !list) {
    return;
  }

  const showFiles = (files) => {
    list.textContent = [...files].map((file) => `- ${file.name}`).join("\n");
  };

  zone.addEventListener("dragover", (event) => {
    event.preventDefault();
    zone.classList.add("dragover");
  });

  zone.addEventListener("dragleave", () => {
    zone.classList.remove("dragover");
  });

  zone.addEventListener("drop", (event) => {
    event.preventDefault();
    zone.classList.remove("dragover");

    if (!event.dataTransfer || !event.dataTransfer.files) {
      return;
    }

    input.files = event.dataTransfer.files;
    showFiles(event.dataTransfer.files);
  });

  input.addEventListener("change", () => {
    showFiles(input.files);
  });
})();
