//
//  OnboardingView_iOS.swift
//  MirrorCal-iOS
//

import SwiftUI

struct OnboardingView_iOS: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentStep = 0
    @State private var isRequestingPermission = false
    
    private let permissionsManager = PermissionsManager_iOS()
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: steps[currentStep].icon)
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text(steps[currentStep].title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(steps[currentStep].description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .id(currentStep)
            
            Spacer()
            
            Button(action: nextStep) {
                Text(currentStep == steps.count - 1 ? "Get Started" : "Next")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(15)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
            .disabled(isRequestingPermission)
        }
    }
    
    private func nextStep() {
        if currentStep == 1 {
            Task {
                isRequestingPermission = true
                _ = await permissionsManager.requestFullAccess()
                isRequestingPermission = false
                withAnimation { currentStep += 1 }
            }
        } else if currentStep < steps.count - 1 {
            withAnimation { currentStep += 1 }
        } else {
            withAnimation {
                hasCompletedOnboarding = true
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
        }
    }
    
    private let steps = [
        OnboardingStep_iOS(icon: "sparkles", title: "Welcome", description: "Mirror calendars easily."),
        OnboardingStep_iOS(icon: "lock.shield", title: "Privacy", description: "We need access to your calendars."),
        OnboardingStep_iOS(icon: "checkmark.circle.fill", title: "All Set!", description: "Configure in settings.")
    ]
}

struct OnboardingStep_iOS {
    let icon: String
    let title: String
    let description: String
}
