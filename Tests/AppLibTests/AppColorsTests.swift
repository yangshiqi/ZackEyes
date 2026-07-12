import Testing
@testable import AppLib

struct AppColorsTests {
    @Test
    func functionalTokensHavePinnedSRGBValues() {
        #expect(AppColors.activity.red == 79.0 / 255)
        #expect(AppColors.activity.green == 203.0 / 255)
        #expect(AppColors.activity.blue == 195.0 / 255)

        #expect(AppColors.information.red == 120.0 / 255)
        #expect(AppColors.information.green == 168.0 / 255)
        #expect(AppColors.information.blue == 216.0 / 255)

        #expect(AppColors.attention.red == 242.0 / 255)
        #expect(AppColors.attention.green == 181.0 / 255)
        #expect(AppColors.attention.blue == 68.0 / 255)

        #expect(AppColors.critical.red == 240.0 / 255)
        #expect(AppColors.critical.green == 90.0 / 255)
        #expect(AppColors.critical.blue == 90.0 / 255)

        #expect(AppColors.idle.red == 142.0 / 255)
        #expect(AppColors.noData.red == 1)
    }

    @Test
    func swiftUIAndAppKitUseTheSameTokenComponents() {
        let color = AppColors.information.nsColor
        #expect(abs(Double(color.redComponent) - AppColors.information.red) < 0.001)
        #expect(abs(Double(color.greenComponent) - AppColors.information.green) < 0.001)
        #expect(abs(Double(color.blueComponent) - AppColors.information.blue) < 0.001)
    }

    @Test
    func quotaAndContextPressureUseNamedDomainThresholds() {
        #expect(UsagePressure.level(for: 49.9) == .activity)
        #expect(UsagePressure.level(for: 50) == .attention)
        #expect(UsagePressure.level(for: 85) == .critical)

        #expect(ContextPressure.level(for: 59.9) == .activity)
        #expect(ContextPressure.level(for: 60) == .attention)
        #expect(ContextPressure.level(for: 85) == .critical)
    }
}
