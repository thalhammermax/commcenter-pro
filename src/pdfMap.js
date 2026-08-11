import * as pdfjsLib from "pdfjs-dist";
import pdfWorker from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjsLib.GlobalWorkerOptions.workerSrc = pdfWorker;

function clamp(value,min,max){
  return Math.max(min,Math.min(max,value));
}

export function normalizePdfCrop(crop){
  const x=clamp(Number(crop?.x ?? 0),0,1);
  const y=clamp(Number(crop?.y ?? 0),0,1);
  const width=clamp(Number(crop?.width ?? 1),0.001,1-x);
  const height=clamp(Number(crop?.height ?? 1),0.001,1-y);
  return {x,y,width,height};
}

async function renderFirstPdfCanvas(file,targetWidth=5000){
  const bytes=new Uint8Array(await file.arrayBuffer());
  const pdf=await pdfjsLib.getDocument({data:bytes}).promise;
  const page=await pdf.getPage(1);

  const base=page.getViewport({scale:1});
  const scale=Math.min(Number(targetWidth||5000)/base.width,6);
  const viewport=page.getViewport({scale});

  const canvas=document.createElement("canvas");
  canvas.width=Math.max(1,Math.round(viewport.width));
  canvas.height=Math.max(1,Math.round(viewport.height));

  await page.render({
    canvasContext:canvas.getContext("2d"),
    viewport
  }).promise;

  return {
    canvas,
    pageCount:pdf.numPages,
    sourceAspect:base.width/base.height
  };
}

async function canvasToWebp(canvas){
  return new Promise((resolve,reject)=>{
    canvas.toBlob(
      blob=>blob?resolve(blob):reject(new Error("Could not render WebP.")),
      "image/webp",
      0.92
    );
  });
}

export async function createFirstPdfPagePreview(file,targetWidth=1400){
  return renderFirstPdfCanvas(file,targetWidth);
}

export async function renderFirstPdfCrop(file,crop,targetWidth=5000){
  const normalized=normalizePdfCrop(crop);

  // Preserve close to the old ~5000px map width for ordinary margin crops
  // without allowing a tiny crop to force an enormous full-page raster.
  const fullRenderTarget=Math.min(
    6500,
    Math.max(targetWidth,Math.round(targetWidth/normalized.width))
  );

  const rendered=await renderFirstPdfCanvas(file,fullRenderTarget);
  const source=rendered.canvas;

  const sx=Math.max(0,Math.round(normalized.x*source.width));
  const sy=Math.max(0,Math.round(normalized.y*source.height));
  const sw=Math.max(1,Math.min(source.width-sx,Math.round(normalized.width*source.width)));
  const sh=Math.max(1,Math.min(source.height-sy,Math.round(normalized.height*source.height)));

  const cropped=document.createElement("canvas");
  cropped.width=sw;
  cropped.height=sh;

  const ctx=cropped.getContext("2d");
  ctx.drawImage(source,sx,sy,sw,sh,0,0,sw,sh);

  const blob=await canvasToWebp(cropped);

  // Release the large temporary canvas as soon as possible.
  source.width=1;
  source.height=1;

  return {
    blob,
    width:cropped.width,
    height:cropped.height,
    pageCount:rendered.pageCount,
    crop:normalized
  };
}

export async function renderFirstPdfPage(file,targetWidth=5000){
  return renderFirstPdfCrop(file,{x:0,y:0,width:1,height:1},targetWidth);
}
