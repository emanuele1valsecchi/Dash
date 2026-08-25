String getFirstLetters(String s1, String s2) => 
  '${s1.isNotEmpty ? s1[0].toUpperCase() : ''}${s2.isNotEmpty ? s2[0].toUpperCase() : ''}';

String formatNumber(int number) {
    if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}k';
    }
    return number.toString();
  }