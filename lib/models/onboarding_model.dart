class OnboardingContent {
  String image;
  String title;
  String description;

  OnboardingContent({required this.image, required this.title, required this.description});
}

List<OnboardingContent> contents = [
  OnboardingContent(
    title: "The world is your circuit!",
    image: 'assets/images/WelcomePage1.png',
    description: "Don't just run a route - own it. DASH transforms your neighborhood into a map for you to claim, conquer, and expand."
  ),
  OnboardingContent(
    title: "Take Their Ground",
    image: 'assets/images/WelcomePage2.png',
    description: "See a territory you want? Close a loop around it. The ground you circle is taken from its owner and added to your map. Your legs draw the border."
  ),
  OnboardingContent(
    title: "Rule Your Territory!",
    image: 'assets/images/WelcomePage3.png',
    description: "Track your dominance with real-time stats. From pace and distance to total land claimed, see how you stack up against the world."
  ),
];

