import Testing

@testable import CalDesign

@Suite("CalAvatar")
struct CalAvatarTests {
    @Test("the four session tones are distinct")
    func activityCases() {
        let tones: [CalAvatar.Activity] = [.idle, .listening, .thinking, .speaking]
        #expect(Set(tones.map { "\($0)" }).count == 4)
    }

    @Test("speaking is the only tone VoiceOver names as speaking")
    func speakingValue() {
        #expect(CalAvatar.Activity.speaking.accessibilityValue == "Speaking")
        #expect(CalAvatar.Activity.listening.accessibilityValue == "Listening")
        #expect(CalAvatar.Activity.thinking.accessibilityValue == "Thinking")
        #expect(CalAvatar.Activity.idle.accessibilityValue.isEmpty)
    }

    @Test("hero and card pad enough for the ring to breathe")
    func layoutInsetCoversHaloAndBob() {
        // Halo ~1.12× side; bob ±7. Inset must clear that so parents do not clip.
        #expect(CalAvatar.Size.hero.layoutInset >= CalAvatar.Size.hero.points * 0.12 + 7)
        #expect(CalAvatar.Size.card.layoutInset >= CalAvatar.Size.card.points * 0.12 + 7)
        #expect(CalAvatar.Size.hero.layoutInset > CalAvatar.Size.card.layoutInset)
    }
}
