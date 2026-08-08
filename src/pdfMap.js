import * as pdfjsLib from "pdfjs-dist";
import pdfWorker from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjsLib.GlobalWorkerOptions.workerSrc = pdfWorker;

export async function renderFirstPdfPage(file, targetWidth=5000) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pdf = await pdfjsLib.getDocument({data:bytes}).promise;
  const page = await pdf.getPage(1);

  const base = page.getViewport({scale:1});
  const scale = Math.min(targetWidth / base.width, 6);
  const viewport = page.getViewport({scale});

  const canvas = document.createElement("canvas");
  canvas.width = Math.round(viewport.width);
  canvas.height = Math.round(viewport.height);

  await page.render({
    canvasContext:canvas.getContext("2d"),
    viewport
  }).promise;

  const blob = await new Promise((resolve,reject)=>{
    canvas.toBlob(b=>b?resolve(b):reject(new Error("Could not render WebP.")), "image/webp", 0.92);
  });

  return {
    blob,
    width:canvas.width,
    height:canvas.height,
    pageCount:pdf.numPages
  };
}
