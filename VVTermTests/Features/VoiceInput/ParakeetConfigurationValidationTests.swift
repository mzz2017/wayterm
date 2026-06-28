import Foundation
import Testing
@testable import VVTerm

#if arch(arm64)
// Test Context:
// These tests protect Parakeet model loading from crashing the app when a
// downloaded or bundled model contains unsupported configuration values. Update
// these tests when VVTerm intentionally supports new Parakeet config shapes,
// not when MLX module internals move.
struct ParakeetConfigurationValidationTests {
    @Test
    func validMinimalConfigurationPassesBeforeModuleConstruction() throws {
        let config = try makeConfig()

        try ParakeetTDT.validateConfiguration(config)
    }

    @Test
    func localAttentionRequiresTwoPositiveContextValues() throws {
        let missingContext = try makeConfig(
            selfAttentionModel: "rel_pos_local_attn",
            attContextSize: "[128]"
        )
        let nonPositiveContext = try makeConfig(
            selfAttentionModel: "rel_pos_local_attn",
            attContextSize: "[128, 0]"
        )

        try expectModelLoadingError(
            from: missingContext,
            containing: "two att_context_size values"
        )
        try expectModelLoadingError(
            from: nonPositiveContext,
            containing: "context sizes must be positive"
        )
    }

    @Test
    func unsupportedJointActivationThrowsInsteadOfCrashing() throws {
        let config = try makeConfig(jointActivation: "gelu")

        try expectModelLoadingError(
            from: config,
            containing: "Unsupported joint activation"
        )
    }

    @Test
    func unsupportedSubsamplingThrowsInsteadOfCrashing() throws {
        let config = try makeConfig(
            subsamplingFactor: 2,
            subsampling: "striding"
        )

        try expectModelLoadingError(
            from: config,
            containing: "Only non-causal dw_striding subsampling"
        )
    }

    @Test
    func unsupportedConvolutionKernelThrowsInsteadOfCrashing() throws {
        let config = try makeConfig(convKernelSize: 30)

        try expectModelLoadingError(
            from: config,
            containing: "conv_kernel_size must be odd"
        )
    }

    private func expectModelLoadingError(
        from config: ParakeetTDTConfig,
        containing expectedMessage: String
    ) throws {
        do {
            try ParakeetTDT.validateConfiguration(config)
            Issue.record("Expected Parakeet configuration validation to fail.")
        } catch ParakeetError.modelLoadingError(let message) {
            #expect(
                message.contains(expectedMessage),
                "Model loading error should describe the unsupported configuration."
            )
        } catch {
            Issue.record("Expected modelLoadingError, got \(error).")
        }
    }

    private func makeConfig(
        selfAttentionModel: String = "rel_pos",
        attContextSize: String = "[128, 128]",
        jointActivation: String = "relu",
        subsamplingFactor: Int = 1,
        subsampling: String = "dw_striding",
        convKernelSize: Int = 31,
        featIn: Int = 80
    ) throws -> ParakeetTDTConfig {
        let json = """
        {
          "preprocessor": {
            "sample_rate": 16000,
            "normalize": "per_feature",
            "window_size": 0.02,
            "window_stride": 0.01,
            "window": "hann",
            "features": 80,
            "n_fft": 512,
            "dither": 0.0,
            "pad_to": 0,
            "pad_value": 0.0,
            "preemph": 0.97
          },
          "encoder": {
            "feat_in": \(featIn),
            "n_layers": 1,
            "d_model": 8,
            "n_heads": 2,
            "ff_expansion_factor": 4,
            "subsampling_factor": \(subsamplingFactor),
            "self_attention_model": "\(selfAttentionModel)",
            "subsampling": "\(subsampling)",
            "conv_kernel_size": \(convKernelSize),
            "subsampling_conv_channels": 4,
            "pos_emb_max_len": 32,
            "att_context_size": \(attContextSize)
          },
          "decoder": {
            "blank_as_pad": false,
            "vocab_size": 2,
            "prednet": {
              "pred_hidden": 8,
              "pred_rnn_layers": 1
            }
          },
          "joint": {
            "num_classes": 2,
            "vocabulary": ["a", "b"],
            "jointnet": {
              "joint_hidden": 8,
              "activation": "\(jointActivation)",
              "encoder_hidden": 8,
              "pred_hidden": 8
            }
          },
          "decoding": {
            "model_type": "tdt",
            "durations": [0, 1],
            "greedy": {
              "max_symbols": 10
            }
          }
        }
        """

        return try JSONDecoder().decode(ParakeetTDTConfig.self, from: Data(json.utf8))
    }
}
#endif
