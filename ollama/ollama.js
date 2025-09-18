import ollama from "ollama";
// Crée une fonction pour générer un email avec Ollama
const generateEmail = async (message) => {
  try {
    // Appelle le modèle pour générer la réponse
    debugger;
    const response = await ollama.chat({
      model: "llama3.2", // Modèle utilisé
      messages: [{ role: "user", content: message }],
    });

    console.log("Réponse : ", response.message.content);
  } catch (error) {
    console.error("Erreur lors de la génération de l'email : ", error.message);
  }
};

// Récupère le message depuis les arguments en ligne de commande
const message =
  "Rédige moi un email professionnel que je dois envoyer à un client pour le remercirer de nous avoir fait confiance";
// if (!message) {
//   console.error("Veuillez fournir un message en argument.");
//   process.exit(1);
// }

// Exécute la fonction pour générer l'email
generateEmail(message);
