const MAX_IMAGE_SIDE = 1600;
const IMAGE_QUALITY = 0.72;
const OUTPUT_TYPE = "image/webp";

function canCompressImage(file: File) {
  return typeof document !== "undefined" && file.type.startsWith("image/");
}

function compressedImageName(fileName: string) {
  const cleanBase = fileName.replace(/\.[^.]+$/, "").trim() || "archivo";
  return `${cleanBase}.webp`;
}

function canvasToBlob(canvas: HTMLCanvasElement) {
  return new Promise<Blob | null>((resolve) => {
    canvas.toBlob(resolve, OUTPUT_TYPE, IMAGE_QUALITY);
  });
}

async function loadImage(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if ("createImageBitmap" in globalThis) {
    return createImageBitmap(file);
  }

  const objectUrl = URL.createObjectURL(file);

  try {
    return await new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = reject;
      image.src = objectUrl;
    });
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

export async function prepareUploadFile(file: File) {
  if (!canCompressImage(file)) {
    return file;
  }

  try {
    const image = await loadImage(file);
    const sourceWidth = image.width;
    const sourceHeight = image.height;

    if (!sourceWidth || !sourceHeight) {
      return file;
    }

    const scale = Math.min(1, MAX_IMAGE_SIDE / Math.max(sourceWidth, sourceHeight));
    const width = Math.max(1, Math.round(sourceWidth * scale));
    const height = Math.max(1, Math.round(sourceHeight * scale));
    const canvas = document.createElement("canvas");

    canvas.width = width;
    canvas.height = height;

    const context = canvas.getContext("2d");

    if (!context) {
      return file;
    }

    context.drawImage(image, 0, 0, width, height);

    if ("close" in image) {
      image.close();
    }

    const blob = await canvasToBlob(canvas);

    if (!blob || blob.size >= file.size) {
      return file;
    }

    return new File([blob], compressedImageName(file.name), {
      type: OUTPUT_TYPE,
      lastModified: Date.now(),
    });
  } catch {
    return file;
  }
}
