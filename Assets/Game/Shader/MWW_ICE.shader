Shader "Unlit/MWW_ICE"
{
    Properties
    {
        [Header(Surface Color)]
        _BaseMap ("Albedo", 2D) = "white" {}
        _BaseColor ("Base Color (Tint)", Color) = (0.7, 0.9, 1.0, 0.1) 
        
        [Header(Surface Detail)]
        _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Strength", Range(0, 2)) = 1.0
        
        [Header(PBR Properties)]
        _Metallic ("Metallic", Range(0, 1)) = 0.0
        _Smoothness ("Smoothness", Range(0.1, 1.0)) = 0.98
        
        [Header(Fresnel and Reflection)]
        [HDR] _FresnelColor ("Fresnel Edge Color", Color) = (2.0, 2.5, 3.0, 1.0)
        _FresnelPower ("Fresnel Power", Range(0.5, 10)) = 5.0

        [Header(Refraction)]
        _Distortion ("Refraction Strength", Range(0, 0.2)) = 0.05
    }

    SubShader
    {
        Tags 
        { 
            "RenderType" = "Transparent" 
            "Queue" = "Transparent"
            "RenderPipeline" = "UniversalPipeline" 
        }

        LOD 300

        // Pass 1: 背面 (Back Face)
        // 只模拟了简单的内部遮挡（变暗）和基于视角的内部反光
        Pass
        {
            Name "InnerFace"
            Tags { "LightMode" = "SRPDefaultUnlit" }

            Cull Front
            ZWrite Off
            Blend One One

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; float2 uv : TEXCOORD0;};
            struct Varyings { float4 positionCS : SV_POSITION; float3 normalWS : TEXCOORD1; float3 viewDirWS : TEXCOORD3; float2 uv : TEXCOORD0;};

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float4 _FresnelColor;
            CBUFFER_END
            
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);

            Varyings Vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS);
                output.positionCS = vertexInput.positionCS;
                output.normalWS = normalInput.normalWS;
                output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                // 简单的内部渲染
                float3 viewDirWS = SafeNormalize(input.viewDirWS);
                float3 normalWS = SafeNormalize(input.normalWS);

                // 模拟光线在冰块内部全反射产生的亮边
                float NdotV = saturate(dot(-normalWS, viewDirWS));
                
                // 边缘越锋利，反光越强。乘上 FresnelColor 让反光带一点微弱的蓝
                float innerRim = pow(1.0 - NdotV, 4.0);
                float3 innerColor = _FresnelColor.rgb * innerRim * 2.0;

                // 返回颜色，Alpha 设为 1 (因为我们改用了 One One 混合模式，不需要 alpha 混合)
                return half4(innerColor, 1.0);
            }
            ENDHLSL
        }

        // Pass 2: 正面 (Front Face) - 核心 Pass
        // 包含：深度写入(解决排序)、体积吸收(解决质感)、折射、菲涅尔效应、brdf光照
        Pass
        {
            Name "OuterFace"
            Tags { "LightMode" = "UniversalForward" } 

            Cull Back
            ZWrite On 
            ZTest LEqual
            Blend SrcAlpha OneMinusSrcAlpha 

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/GlobalIllumination.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float4 tangentOS    : TANGENT;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 normalWS     : TEXCOORD1;
                float3 positionWS   : TEXCOORD2;
                float3 viewDirWS    : TEXCOORD3;
                float4 screenPos    : TEXCOORD4;
                float3 tangentWS    : TEXCOORD5;
                float3 bitangentWS  : TEXCOORD6;
            };

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float4 _FresnelColor;
                float4 _BumpMap_ST;
                float _BumpScale;
                float _Smoothness;
                float _Distortion;
                float _FresnelPower;
                float _Metallic;
            CBUFFER_END

            TEXTURE2D(_BumpMap); SAMPLER(sampler_BumpMap);
            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_BrdfLUT); SAMPLER(sampler_BrdfLUT);

            Varyings Vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = vertexInput.positionCS;
                output.positionWS = vertexInput.positionWS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.normalWS = normalInput.normalWS;
                output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
                output.tangentWS = normalInput.tangentWS;
                output.bitangentWS = normalInput.bitangentWS;
                output.screenPos = ComputeScreenPos(vertexInput.positionCS);
                return output;
            }

            float D_GGX_TR(float3 N, float3 H, float a)
            {
                float a2     = a*a;
                float NdotH  = max(dot(N, H), 0.0);
                float NdotH2 = NdotH*NdotH;
            
                float nom    = a2;
                float denom  = (NdotH2 * (a2 - 1.0) + 1.0);
                denom        = PI * denom * denom;
            
                return nom / denom;
            }
            
            // Smith几何遮蔽函数
            float GeometrySmith(float NdotV, float NdotL, float roughness)
            {
                half k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
                half G1 = NdotV / (NdotV * (1 - k) + k);
                half G2 = NdotL / (NdotL * (1 - k) + k);
                return G1 * G2;
            }
            
            // Schlick菲涅尔近似
            float3 Fresnel(half3 F0, float VdotH)
            {
                return F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
            }
            
            // BRDF计算
            half3 BRDF(float D, half G, float3 F, float NdotV, float NdotL)
            {
                return (D * G * F) / (4.0 * NdotL * NdotV + 1e-5);
            }

            half4 Frag(Varyings input) : SV_Target
            {
                // --- 1. 光照模型 ---
                // BRDF数据准备
                float3 viewDirWS = SafeNormalize(input.viewDirWS);
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                half4 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv) * _BaseColor;
                half3 surAlbedo = albedo.rgb;
                half metallic = _Metallic;
                half smoothness = _Smoothness;
                half3 specular = lerp(0.04, surAlbedo.rgb, metallic);
                half roughness = 1.0 - smoothness;
                half3 F0 = specular;

                // 主光源
                Light mainLight = GetMainLight();
                half3 lightDir = mainLight.direction;
                half3 lightColor = mainLight.color * mainLight.distanceAttenuation * mainLight.shadowAttenuation;

                // 法线处理
                float3 NormalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
                float3x3 TBN = float3x3(input.tangentWS, input.bitangentWS, input.normalWS);
                float3 normalWS = TransformTangentToWorld(NormalTS, TBN);
                normalWS = NormalizeNormalPerPixel(normalWS);

                half NdotL = saturate(dot(normalWS, lightDir)) ;
                half3 halfDir = SafeNormalize(lightDir + viewDirWS);
                half NdotH = saturate(dot(normalWS, halfDir));
                half NdotV = saturate(dot(normalWS, viewDirWS));
                half VdotH = saturate(dot(viewDirWS, halfDir));

                // BRDF计算
                float D = D_GGX_TR(normalWS, halfDir, roughness);
                half G = GeometrySmith(NdotV, NdotL, roughness);
                float3 F = Fresnel(F0, VdotH);
                
                // 组合BRDF
                half3 specularTerm = saturate(BRDF(D, G, F, NdotV, NdotL));
                specularTerm *= lightColor * NdotL;
                
                // 环境光镜面反射
                half3 reflectVec = reflect(-viewDirWS, normalWS);
                half mip = roughness * 6;
                half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVec, mip);
                half3 irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);

                // BRDF LUT采样
                half2 envBRDF = SAMPLE_TEXTURE2D_LOD(_BrdfLUT, sampler_BrdfLUT, float2(NdotV, roughness), 0).rg;
                half3 ambientSpecular = irradiance * (F * envBRDF.x + envBRDF.y);

                // 湿润度高光
                float wetnessSpecific = saturate(pow(NdotH, 512.0));
                // 让这个高光非常亮 (乘以 2 或 3)，并且只受主光影响
                float3 wetSpecular = lightColor * wetnessSpecific * 5.0;

                // --- 2. 折射计算 ---
                float2 distortion = NormalTS.xy * _Distortion; 
                float2 distortedUV = screenUV + distortion;
                
                // --- 3. 采样背景颜色 ---
                float3 sceneColor = SampleSceneColor(distortedUV).rgb;
                
                // --- 4. 颜色混合 ---
                float3 finalColor = sceneColor * albedo.rgb;
                
                // --- 5. 菲涅尔与边缘光 ---
                float fresnel = saturate(pow(1.0 - NdotV, _FresnelPower));
                // 叠加边缘光
                half3 rimLighting = lightColor * NdotL;
                // 边缘光 = 菲涅尔系数 * 颜色 * 总光照
                half3 rimColor = rimLighting * _FresnelColor.rgb * fresnel;
                finalColor += rimColor;

                 // 最终颜色
                finalColor += specularTerm + wetSpecular + ambientSpecular * fresnel * NdotL;

                return half4(finalColor, 1);
            }
            
            ENDHLSL
        }
    }
}
