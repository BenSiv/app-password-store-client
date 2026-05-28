# Password Store Client Makefile

# Build local debug APK
build-local:
	@echo "Building local Android debug APK..."
	@flutter build apk --debug

# Build production bundle (Android AAB)
build:
	@echo "Building production App Bundle..."
	@flutter build appbundle --release

# Clean output
clean:
	@echo "Cleaning up..."
	@flutter clean

# Deploy to Google Play Store using Fastlane
deploy-play:
	@echo "Deploying to Google Play Store..."
	@bundle exec fastlane android deploy
