#include "cGraphics.fxh"
#include "cImageProcessing.fxh"

#if !defined(CVIDEOPROCESSING_FXH)
    #define CVIDEOPROCESSING_FXH

    /*
        [Functions]
    */

    // [-1.0, 1.0] -> [Width, Height]
    float2 DecodeVectors(float2 Vectors, float2 ImageSize)
    {
        return Vectors / abs(ImageSize);
    }

    // [Width, Height] -> [-1.0, 1.0]
    float2 EncodeVectors(float2 Vectors, float2 ImageSize)
    {
        return clamp(Vectors * abs(ImageSize), -1.0, 1.0);
    }

    /*
        Lucas-Kanade optical flow with bilinear fetches
        ---
        Calculate Lucas-Kanade optical flow by solving (A^-1 * B)
        [A11 A12]^-1 [-B1] -> [ A11/D -A12/D] [-B1]
        [A21 A22]^-1 [-B2] -> [-A21/D  A22/D] [-B2]
        ---
        [ Ix^2/D -IxIy/D] [-IxIt]
        [-IxIy/D  Iy^2/D] [-IyIt]
    */

    struct Texel
    {
        float4 MainTex;
        float4 Mask;
        float4 LOD;
    };

    float2x2 GetGradients(sampler2D Source, float2 Tex, Texel Input)
    {
        float4 NS = Tex.xyxy + float4(0.0, -1.0, 0.0, 1.0);
        float4 EW = Tex.xyxy + float4(-1.0, 0.0, 1.0, 0.0);

        float2 N = tex2Dlod(Source, (NS.xyyy * Input.Mask) + Input.LOD.xxxy).rg;
        float2 S = tex2Dlod(Source, (NS.zwww * Input.Mask) + Input.LOD.xxxy).rg;
        float2 E = tex2Dlod(Source, (EW.xyyy * Input.Mask) + Input.LOD.xxxy).rg;
        float2 W = tex2Dlod(Source, (EW.zwww * Input.Mask) + Input.LOD.xxxy).rg;

        float2x2 OutputColor;
        OutputColor[0] = E - W;
        OutputColor[1] = N - S;
        return OutputColor;
    }

    float2 GetPixelPyLK
    (
        float2 MainTex,
        float2 Vectors,
        sampler2D SampleI0,
        sampler2D SampleI1
    )
    {
        // Initialize variables
        Texel TxData;
        float IxIx = 0.0;
        float IyIy = 0.0;
        float IxIy = 0.0;
        float IxIt = 0.0;
        float IyIt = 0.0;

        // Get required data to calculate main texel data
        const int WindowSize = 4;
        const float2 WindowHalf = trunc(WindowSize / 2) - 0.5;
        const float2 ImageSize = tex2Dsize(SampleI0, 0.0);
        float2 PixelSize = float2(ddx(MainTex.x),  ddy(MainTex.y));

        // Calculate main texel data (TexelSize, TexelLOD)
        TxData.Mask = float4(1.0, 1.0, 0.0, 0.0) * abs(PixelSize.xyyy);
        TxData.MainTex.xy = MainTex;
        TxData.MainTex.zw = TxData.MainTex.xy + Vectors;
        TxData.LOD.xy = GetLOD(TxData.MainTex.xy * ImageSize);
        TxData.LOD.zw = GetLOD(TxData.MainTex.zw * ImageSize);

        // Un-normalize data for processing
        TxData.MainTex *= (1.0 / abs(PixelSize.xyxy));
        Vectors = DecodeVectors(Vectors, PixelSize);

        // Start from the negative so we can process a window in 1 loop
        [loop] for (int i = 0; i < (WindowSize * WindowSize); i++)
        {
            float2 Shift = -WindowHalf + float2(i % WindowSize, trunc(i / WindowSize));
            float4 Tex = TxData.MainTex + Shift.xyxy;

            float2x2 G = GetGradients(SampleI0, Tex.xy, TxData);
            float2 I0 = tex2Dlod(SampleI0, (Tex.xyyy * TxData.Mask) + TxData.LOD.xxxy).rg;
            float2 I1 = tex2Dlod(SampleI1, (Tex.zwww * TxData.Mask) + TxData.LOD.zzzw).rg;
            float2 IT = I0 - I1;

            // A.x = A11; A.y = A22; A.z = A12/A22
            IxIx += dot(G[0].rg, G[0].rg);
            IyIy += dot(G[1].rg, G[1].rg);
            IxIy += dot(G[0].rg, G[1].rg);

            // B.x = B1; B.y = B2
            IxIt += dot(G[0].rg, IT.rg);
            IyIt += dot(G[1].rg, IT.rg);
        }

        /*
            Calculate Lucas-Kanade matrix
            ---
            [ Ix^2/D -IxIy/D] [-IxIt]
            [-IxIy/D  Iy^2/D] [-IyIt]
        */

        // Calculate A^-1 and B
        float D = determinant(float2x2(IxIx, IxIy, IxIy, IyIy));
        float2x2 A = float2x2(IyIy, -IxIy, -IxIy, IxIx) / D;
        float2 B = float2(-IxIt, -IyIt);

        // Calculate A^T*B
        float2 Flow = (D == 0.0) ? 0.0 : mul(B, A);

        // Propagate and encode vectors
        return EncodeVectors(Vectors + Flow, PixelSize);
    }

    struct Block
    {
        float4 MainTex;
        float4 Mask;
        float4 LOD;
        float4x4 Shifts;
    };

    void SampleBlock(sampler2D Source, float4x4 HalfPixel, Block Input, float2 LOD, out float4 Pixel[8])
    {
        Pixel[0].xy = tex2Dlod(Source, (HalfPixel[0].xzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[1].xy = tex2Dlod(Source, (HalfPixel[0].xwww * Input.Mask) + LOD.xxxy).xy;
        Pixel[2].xy = tex2Dlod(Source, (HalfPixel[0].yzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[3].xy = tex2Dlod(Source, (HalfPixel[0].ywww * Input.Mask) + LOD.xxxy).xy;
        Pixel[4].xy = tex2Dlod(Source, (HalfPixel[1].xzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[5].xy = tex2Dlod(Source, (HalfPixel[1].xwww * Input.Mask) + LOD.xxxy).xy;
        Pixel[6].xy = tex2Dlod(Source, (HalfPixel[1].yzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[7].xy = tex2Dlod(Source, (HalfPixel[1].ywww * Input.Mask) + LOD.xxxy).xy;

        Pixel[0].zw = tex2Dlod(Source, (HalfPixel[2].xzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[1].zw = tex2Dlod(Source, (HalfPixel[2].xwww * Input.Mask) + LOD.xxxy).xy;
        Pixel[2].zw = tex2Dlod(Source, (HalfPixel[2].yzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[3].zw = tex2Dlod(Source, (HalfPixel[2].ywww * Input.Mask) + LOD.xxxy).xy;
        Pixel[4].zw = tex2Dlod(Source, (HalfPixel[3].xzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[5].zw = tex2Dlod(Source, (HalfPixel[3].xwww * Input.Mask) + LOD.xxxy).xy;
        Pixel[6].zw = tex2Dlod(Source, (HalfPixel[3].yzzz * Input.Mask) + LOD.xxxy).xy;
        Pixel[7].zw = tex2Dlod(Source, (HalfPixel[3].ywww * Input.Mask) + LOD.xxxy).xy;
    }

    float GetNCC(float4 T[8], float4 I[8])
    {
        float N1[2];
        float N2[2];
        float N3[2];

        [unroll]
        for (int i = 0; i < 8; i++)
        {
            N1[0] += dot(T[i].xz, I[i].xz);
            N2[0] += dot(T[i].xz, T[i].xz);
            N3[0] += dot(I[i].xz, I[i].xz);

            N1[1] += dot(T[i].yw, I[i].yw);
            N2[1] += dot(T[i].yw, T[i].yw);
            N3[1] += dot(I[i].yw, I[i].yw);
        }

        float NCC[2] =
        {
            N1[0] * rsqrt(N2[0] * N3[0]),
            N1[1] * rsqrt(N2[1] * N3[1]),
        };

        return min(NCC[0], NCC[1]);
    }

    float4x4 GetHalfPixel(Block Input, float2 Tex)
    {
        float4x4 HalfPixel;
        HalfPixel[0] = Tex.xxyy + Input.Shifts[0];
        HalfPixel[1] = Tex.xxyy + Input.Shifts[1];
        HalfPixel[2] = Tex.xxyy + Input.Shifts[2];
        HalfPixel[3] = Tex.xxyy + Input.Shifts[3];
        return HalfPixel;
    }

    float2 SearchArea(sampler2D SampleImage, Block Input, float4 Template[8], float Minimum)
    {
        float2 Vectors = 0.0;

        const int WindowSize = 3;
        const int2 WindowHalf = trunc(WindowSize / 2);

        // Start from the negative so we can process a window in 1 loop
        [loop] for (int i = 0; i < (WindowSize * WindowSize); i++)
        {
            int2 Shift = -WindowHalf + int2(i % WindowSize, trunc(i / WindowSize));
            if (all(Shift == 0))
            {
                continue;
            }

            float4 Image[8];
            float4x4 HalfPixel = GetHalfPixel(Input, Input.MainTex.zw + Shift);
            SampleBlock(SampleImage, HalfPixel, Input, Input.LOD.zw, Image);
            float NCC = GetNCC(Template, Image);

            Vectors = (NCC > Minimum) ? Shift : Vectors;
            Minimum = max(NCC, Minimum);
        }

        return Vectors;
    }

    float2 GetPixelMFlow
    (
        float2 MainTex,
        float2 Vectors,
        sampler2D SampleTemplate,
        sampler2D SampleImage,
        int Level
    )
    {
        // Initialize data
        Block BlockData;

        // Get required data to calculate main texel data
        const float2 ImageSize = tex2Dsize(SampleTemplate, 0.0);
        float2 PixelSize = float2(ddx(MainTex.x),  ddy(MainTex.y));

        // Calculate main texel data (TexelSize, TexelLOD)
        BlockData.Mask = float4(1.0, 1.0, 0.0, 0.0) * abs(PixelSize.xyyy);
        BlockData.MainTex.xy = MainTex;
        BlockData.MainTex.zw = BlockData.MainTex.xy + Vectors;
        BlockData.LOD.xy = GetLOD(BlockData.MainTex.xy * ImageSize);
        BlockData.LOD.zw = GetLOD(BlockData.MainTex.zw * ImageSize);

        // Un-normalize data for processing
        BlockData.MainTex *= (1.0 / abs(PixelSize.xyxy));
        Vectors = DecodeVectors(Vectors, PixelSize);

        BlockData.Shifts = float4x4
        (
            float4(-0.5, 0.5, -0.5, 0.5) + float4(-1.0, -1.0,  1.0,  1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4( 1.0,  1.0,  1.0,  1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4(-1.0, -1.0, -1.0, -1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4( 1.0,  1.0, -1.0, -1.0)
        );

        // Initialize variables
        float4 Template[8];
        float4 Image[8];

        // Initialize with center search first
        float4x4 HalfPixel = GetHalfPixel(BlockData, BlockData.MainTex.xy);
        SampleBlock(SampleTemplate, HalfPixel, BlockData, BlockData.LOD.xy, Template);
        SampleBlock(SampleImage, HalfPixel, BlockData, BlockData.LOD.zw, Image);
        float Minimum = GetNCC(Template, Image) + 1e-7;

        // Calculate three-step search
        Vectors += SearchArea(SampleImage, BlockData, Template, Minimum);

        // Propagate and encode vectors
        return EncodeVectors(Vectors, BlockData.Mask.xy);
    }
#endif
