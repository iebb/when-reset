interface SubtleCrypto {
  timingSafeEqual(
    a: ArrayBuffer | ArrayBufferView,
    b: ArrayBuffer | ArrayBufferView
  ): boolean;
}
