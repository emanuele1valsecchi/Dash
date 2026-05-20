class OnboardingContent {
  String image;
  String title;
  String description;

  OnboardingContent({required this.image, required this.title, required this.description});
}

List<OnboardingContent> contents = [
  OnboardingContent(
    title: "The world is your circuit!",
    image: 'assets/images/WlecomePage1.png',
    description: "Don't just run a route - own it. DASH transforms your neighborhood into a map for you to claim, conquer, and defend."
  ),
  OnboardingContent(
    title: "Steal the Crown",
    image: 'assets/images/WlecomePage2.png',
    description: "Take on territory claims from others. Outrun the current champion to claim their zone and mark the map as yours."
  ),
  OnboardingContent(
    title: "Rule Your Territory!",
    image: 'assets/images/WlecomePage3.png',
    description: "Track your dominance with real-time stats and audio coaching. From average speed to total land grabbed, see how you stack up against the world."
  ),
];

