package com.chess.backend.payments;

import java.util.Map;

public class CoinPackages {

    public record Package(int coins, int npr, String label) {}

    public static final Map<String, Package> PACKAGES = Map.of(
            "small", new Package(100, 10, "100 Coins"),
            "medium", new Package(500, 40, "500 Coins"),
            "large", new Package(1000, 70, "1000 Coins")
    );

    public static Package get(String packageId) {
        return PACKAGES.get(packageId);
    }

    private CoinPackages() {}
}
