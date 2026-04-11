RSpec.describe "TopLevel" do
  context "when nested" do
    it "passes" do
      expect(true).to be true
    end
  end

  describe "another nested" do
    context "deeply nested" do
      it "also passes" do
        expect(1).to eq(1)
      end
    end
  end
end
