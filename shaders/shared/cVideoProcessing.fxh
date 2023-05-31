#include "shared/cGraphics.fxh"

#if !defined(CVIDEOPROCESSING_FXH)
    #define CVIDEOPROCESSING_FXH

    // Lucas-Kanade optical flow with bilinear fetches

    /*
        Calculate Lucas-Kanade optical flow by solving (A^-1 * B)
        ---------------------------------------------------------
        [A11 A12]^-1 [-B1] -> [ A11/D -A12/D] [-B1]
        [A21 A22]^-1 [-B2] -> [-A21/D  A22/D] [-B2]
        ---------------------------------------------------------
        [ Ix^2/D -IxIy/D] [-IxIt]
        [-IxIy/D  Iy^2/D] [-IyIt]
    */

    struct Texel
    {
        float4 MainTex;
        float4 Mask;
        float2 LOD;
    };

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

    float4 GetSobel(sampler2D Source, float2 Tex, Texel Input)
    {
        float4 NS = Tex.xyxy + float4(0.0, -1.0, 0.0, 1.0);
        float4 EW = Tex.xyxy + float4(-1.0, 0.0, 1.0, 0.0);

        float4 OutputColor = 0.0;
        float2 N = tex2Dlod(Source, (NS.xyyy * Input.Mask) + Input.LOD.xxxy).rg;
        float2 S = tex2Dlod(Source, (NS.zwww * Input.Mask) + Input.LOD.xxxy).rg;
        float2 E = tex2Dlod(Source, (EW.xyyy * Input.Mask) + Input.LOD.xxxy).rg;
        float2 W = tex2Dlod(Source, (EW.zwww * Input.Mask) + Input.LOD.xxxy).rg;
        OutputColor.xz = E - W;
        OutputColor.yw = N - S;

        return OutputColor;
    }

    float2 GetPixelPyLK
    (
        float2 MainTex,
        float2 Vectors,
        sampler2D SampleI0,
        sampler2D SampleI1,
        int Level
    )
    {
        // Initialize variables
        Texel TxData;
        float3 A = 0.0;
        float2 B = 0.0;
        float Determinant = 0.0;
        float2 NewVectors = 0.0;

        // Get required data to calculate main texel data
        float2 TexSize = float2(ddx(MainTex.x), ddy(MainTex.y));
        Vectors = DecodeVectors(Vectors, TexSize);

        // Calculate main texel data (TexelSize, TexelLOD)
        TxData.Mask = float4(1.0, 1.0, 0.0, 0.0) * abs(TexSize.xyyy);
        TxData.MainTex.xy = MainTex * (1.0 / abs(TexSize));
        TxData.MainTex.zw = TxData.MainTex.xy + Vectors;
        TxData.LOD = float2(0.0, float(Level));

        [loop]
        for (int x = -2.5; x <= 2.5; x++)
        [loop]
        for (int y = -2.5; y <= 2.5; y++)
        {
            int2 Shift = int2(x, y);
            float4 Tex = TxData.MainTex + Shift.xyxy;
            float4 Tex0 = (Tex.xyyy * TxData.Mask) + TxData.LOD.xxxy;
            float4 Tex1 = (Tex.zwww * TxData.Mask) + TxData.LOD.xxxy;

            float2 I0 = tex2Dlod(SampleI0, Tex0).rg;
            float2 I1 = tex2Dlod(SampleI1, Tex1).rg;
            float4 G = GetSobel(SampleI0, Tex.xy, TxData);

            // A.x = A11; A.y = A22; A.z = A12/A22
            A.xyz += (G.xyx * G.xyy);
            A.xyz += (G.zwz * G.zww);

            // B.x = B1; B.y = B2
            float2 IT = I0 - I1;
            B += (G.xy * IT.rr);
            B += (G.zw * IT.gg);
        }

        // Create -IxIy (A12) for A^-1 and its determinant
        A.z = -A.z;

        // Calculate A^-1 determinant
        Determinant = (A.x * A.y) - (A.z * A.z);

        // Solve A^-1
        A = A / Determinant;

        // Calculate Lucas-Kanade matrix
        // [ Ix^2/D -IxIy/D] [-IxIt]
        // [-IxIy/D  Iy^2/D] [-IyIt]
        NewVectors = (Determinant != 0.0) ? mul(-B.xy, float2x2(A.yzzx)) : 0.0;

        // Propagate and encode vectors
        return EncodeVectors(Vectors + NewVectors, TxData.Mask.xy);
    }

    struct Block
    {
        float4 MainTex;
        float4 Mask;
        float2 LOD;
        float4x4 Shifts;
    };

    void SampleBlock(sampler2D Source, float4x4 HalfPixel, Block Input, out float4 Pixel[8])
    {
        Pixel[0].xy = tex2Dlod(Source, (HalfPixel[0].xzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[1].xy = tex2Dlod(Source, (HalfPixel[0].xwww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[2].xy = tex2Dlod(Source, (HalfPixel[0].yzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[3].xy = tex2Dlod(Source, (HalfPixel[0].ywww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[4].xy = tex2Dlod(Source, (HalfPixel[1].xzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[5].xy = tex2Dlod(Source, (HalfPixel[1].xwww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[6].xy = tex2Dlod(Source, (HalfPixel[1].yzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[7].xy = tex2Dlod(Source, (HalfPixel[1].ywww * Input.Mask) + Input.LOD.xxxy).xy;

        Pixel[0].zw = tex2Dlod(Source, (HalfPixel[2].xzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[1].zw = tex2Dlod(Source, (HalfPixel[2].xwww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[2].zw = tex2Dlod(Source, (HalfPixel[2].yzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[3].zw = tex2Dlod(Source, (HalfPixel[2].ywww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[4].zw = tex2Dlod(Source, (HalfPixel[3].xzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[5].zw = tex2Dlod(Source, (HalfPixel[3].xwww * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[6].zw = tex2Dlod(Source, (HalfPixel[3].yzzz * Input.Mask) + Input.LOD.xxxy).xy;
        Pixel[7].zw = tex2Dlod(Source, (HalfPixel[3].ywww * Input.Mask) + Input.LOD.xxxy).xy;
    }

    float GetNCC(float4 T[8], float4 I[8])
    {
        float4 N1 = 0.0;
        float4 N2 = 0.0;
        float4 N3 = 0.0;

        [unroll]
        for (int i = 0; i < 8; i++)
        {
            N1 += (T[i] * I[i]);
            N2 += (T[i] * T[i]);
            N3 += (I[i] * I[i]);
        }

        float2 ON1 = N1.xy + N1.zw;
        float2 ON2 = N2.xy + N2.zw;
        float2 ON3 = N3.xy + N3.zw;
        float2 NCC = ON1 * rsqrt(ON2 * ON3);
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

    float2 SearchArea(sampler2D SI, Block Input, float4 TBlock[8], float Minimum)
    {
        float2 Vectors = 0.0;

        [loop]
        for (int x = -1; x <= 1; x++)
        [loop]
        for (int y = -1; y <= 1; y++)
        {
            float2 Shift = int2(x, y);
            if (all(Shift == 0))
            {
                continue;
            }

            float4x4 HalfPixel = GetHalfPixel(Input, Input.MainTex.zw + Shift);
            float4 IBlock[8];
            SampleBlock(SI, HalfPixel, Input, IBlock);
            float NCC = GetNCC(TBlock, IBlock);

            Vectors = (NCC > Minimum) ? Shift : Vectors;
            Minimum = max(NCC, Minimum);
        }

        return Vectors;
    }

    float2 GetPixelMFlow
    (
        float2 MainTex,
        float2 Vectors,
        sampler2D SampleT,
        sampler2D SampleI,
        int Level
    )
    {
        // Initialize data
        Block BlockData;

        // Get required data to calculate main texel data
        float2 TexSize = float2(ddx(MainTex.x), ddy(MainTex.y));
        Vectors = DecodeVectors(Vectors, TexSize);

        // Calculate main texel data (TexelSize, TexelLOD)
        BlockData.Mask = float4(1.0, 1.0, 0.0, 0.0) * abs(TexSize.xyyy);
        BlockData.MainTex.xy = MainTex * (1.0 / abs(TexSize));
        BlockData.MainTex.zw = BlockData.MainTex.xy + Vectors;
        BlockData.LOD = float2(0.0, float(Level));
        BlockData.Shifts = float4x4
        (
            float4(-0.5, 0.5, -0.5, 0.5) + float4(-1.0, -1.0,  1.0,  1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4( 1.0,  1.0,  1.0,  1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4(-1.0, -1.0, -1.0, -1.0),
            float4(-0.5, 0.5, -0.5, 0.5) + float4( 1.0,  1.0, -1.0, -1.0)
        );

        // Initialize variables
        float4 TBlock[8];
        float4 IBlock[8];
        float4x4 HalfPixel = GetHalfPixel(BlockData, BlockData.MainTex.xy);
        SampleBlock(SampleT, HalfPixel, BlockData, TBlock);
        SampleBlock(SampleI, HalfPixel, BlockData, IBlock);
        float Minimum = GetNCC(TBlock, IBlock) + 1e-7;

        // Calculate three-step search
        Vectors += SearchArea(SampleI, BlockData, TBlock, Minimum);

        // Propagate and encode vectors
        return EncodeVectors(Vectors, BlockData.Mask.xy);
    }
#endif
